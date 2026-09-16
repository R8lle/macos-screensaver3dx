import simd

/// A single rain character in 3D space, ready for upload to the instance
/// buffer. Layout must exactly match `Glyph3DInstanceData` in
/// `Shaders/Shaders.metal` (5x float4 = 80 bytes).
struct Glyph3DInstance {
    var center: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var color: SIMD4<Float>
    var uv: SIMD4<Float>
}

/// Volumetric 3D Matrix rain — world columns with depth (world Z).
///
/// Instead of a flat 2D overlay (see `MatrixRainSimulation`), the rain
/// columns live in world space: each column has its own depth (world Z) and
/// falls along world Y. Every character is rendered as a camera-facing
/// billboard with constant world size, so perspective makes nearby
/// characters larger and distant ones smaller.
///
/// Organized as parallel arrays (struct-of-arrays) rather than an array of
/// structs -- keeps per-column state (position, speed, character) separate
/// and easy to update in batches.
final class WorldRain {
    private(set) var width: Float
    private(set) var height: Float
    let preview: Bool
    let atlas: GlyphAtlas
    private(set) var objectZ: Float
    let columnsCount: Int
    let trail: Int
    let glyphHalfW: Float
    let glyphHalfH: Float
    let cellH: Float

    private var colX: [Float]
    private var colZ: [Float]
    private var colY: [Float]
    private var colSpeed: [Float]
    private var colHalfH: [Float]
    private var cellUV: [[SIMD4<Float>]]
    private var cellColor: [[SIMD4<Float>]]
    private var cellGap: [[Bool]]

    private var rightVec = SIMD3<Float>.zero
    private var upVec = SIMD3<Float>.zero

    // Depth range of the rain volume (world Z). Larger = closer to the camera.
    private static let rainZNear: Float = 2.6
    private static let rainZFar: Float = -2.2
    // Vertical margin outside the frustum before a column gets recycled.
    private static let yMargin: Float = 0.6
    // Depth-dependent fade-out: distant rain is slightly darker.
    private static let depthFadeNear: Float = 1.0
    private static let depthFadeFar: Float = 0.5

    init(width: Float, height: Float, preview: Bool, objectZ: Float, atlas: GlyphAtlas, columns: Int, glyphLayoutHeight: Float? = nil, sizeScale: Float = 1.0) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.preview = preview
        self.atlas = atlas
        self.objectZ = objectZ
        self.columnsCount = max(0, columns)
        self.trail = preview ? 20 : 36

        // When the Metal buffer is downscaled (Appex ViewBridge path) but shown
        // fullscreen, size glyphs against the logical display height or they
        // appear far too large after upscaling.
        let layoutH = max(1, glyphLayoutHeight ?? self.height)
        let scale = max(0.25, sizeScale)
        let glyphH = Scene.worldUnitsForPixels(Float(atlas.cellHeight), screenHeight: layoutH, worldZ: Scene.glyphSizeRefZ) * scale
        let glyphW = glyphH * (Float(atlas.cellWidth) / max(1, Float(atlas.cellHeight)))
        self.glyphHalfW = glyphW * 0.5
        self.glyphHalfH = glyphH * 0.5
        self.cellH = glyphH

        colX = [Float](repeating: 0, count: columnsCount)
        colZ = [Float](repeating: 0, count: columnsCount)
        colY = [Float](repeating: 0, count: columnsCount)
        colSpeed = [Float](repeating: 0, count: columnsCount)
        colHalfH = [Float](repeating: 0, count: columnsCount)
        cellUV = [[SIMD4<Float>]](repeating: [SIMD4<Float>](repeating: .zero, count: trail), count: columnsCount)
        cellColor = [[SIMD4<Float>]](repeating: [SIMD4<Float>](repeating: .zero, count: trail), count: columnsCount)
        cellGap = [[Bool]](repeating: [Bool](repeating: false, count: trail), count: columnsCount)

        updateBillboardAxes()
        for i in 0..<columnsCount {
            respawnColumn(i, initial: true)
        }
    }

    private func updateBillboardAxes() {
        let (right, up) = Scene.cameraBillboardAxes(objectZ: objectZ)
        rightVec = right * glyphHalfW
        upVec = up * glyphHalfH
    }

    private func frustumHalfHeight(worldZ: Float) -> Float {
        max(0.1, (Scene.cameraEye.z - worldZ) * tan(Scene.fovY * 0.5))
    }

    private func randomUV() -> SIMD4<Float> {
        let uv = atlas.uv(for: GlyphAtlas.randomChar())
        return SIMD4<Float>(uv.u0, uv.v0, uv.u1, uv.v1)
    }

    /// Head is bright (near white), followed by a smoothly fading green trail.
    /// Brightness in the shader = rgb * alpha (additive).
    private func columnColors(depthFade: Float) -> [SIMD4<Float>] {
        var colors = [SIMD4<Float>](repeating: .zero, count: trail)
        colors[0] = SIMD4<Float>(0.78, 1.0, 0.82, 1.0)

        let bodyGreen = SIMD3<Float>(0.05, 1.0, 0.28)
        let nearGreen = SIMD3<Float>(0.45, 1.0, 0.55)
        // Slightly different trail length per column -> feels more alive.
        let falloff = Float.random(in: 0.5...0.85)
        for j in 1..<trail {
            let t = Float(j - 1) / Float(max(1, trail - 2))
            let bright = pow(1.0 - t, falloff)
            let rgb = bodyGreen + (nearGreen - bodyGreen) * max(0.0, 1.0 - t * 2.0)
            colors[j] = SIMD4<Float>(rgb.x, rgb.y, rgb.z, max(0.14, bright))
        }
        for j in 0..<trail {
            colors[j].w *= depthFade
        }
        return colors
    }

    private func depthFade(for z: Float) -> Float {
        let t = min(1, max(0, (z - Self.rainZFar) / max(1e-6, Self.rainZNear - Self.rainZFar)))
        return Self.depthFadeFar + (Self.depthFadeNear - Self.depthFadeFar) * t
    }

    private func respawnColumn(_ i: Int, initial: Bool) {
        let z = Float.random(in: Self.rainZFar...Self.rainZNear)
        let halfH = frustumHalfHeight(worldZ: z)
        let halfW = halfH * (width / max(1, height))
        colZ[i] = z
        colHalfH[i] = halfH
        colX[i] = Float.random(in: -halfW...halfW) * 1.02
        // Slightly more leisurely falling: ~35% slower than an earlier version.
        colSpeed[i] = preview ? Float.random(in: 0.6...1.2) : Float.random(in: 0.65...1.5)
        if initial {
            colY[i] = Float.random(in: -halfH...(halfH + Float(trail) * cellH))
        } else {
            colY[i] = halfH + Self.yMargin + Float.random(in: 0...(halfH * 0.5))
        }

        let fade = depthFade(for: z)
        cellUV[i] = (0..<trail).map { _ in randomUV() }
        cellColor[i] = columnColors(depthFade: fade)
        // Only a few gaps, so the stream reads as a continuous cascade; the
        // first cells (bright head area) always stay filled.
        cellGap[i] = (0..<trail).map { _ in Float.random(in: 0..<1) < 0.05 }
        for k in 0..<min(4, trail) { cellGap[i][k] = false }
    }

    func resize(width: Float, height: Float) {
        let w = max(1, width), h = max(1, height)
        if abs(self.width - w) < 1 && abs(self.height - h) < 1 { return }
        self.width = w
        self.height = h
    }

    func setObjectZ(_ z: Float) {
        if abs(z - objectZ) > 1e-6 {
            objectZ = z
            updateBillboardAxes()
        }
    }

    func update(dt: Float) {
        guard columnsCount > 0 else { return }
        for i in 0..<columnsCount {
            colY[i] -= colSpeed[i] * dt
        }
        for i in 0..<columnsCount {
            let topCellY = colY[i] + Float(trail - 1) * cellH
            if topCellY < -(colHalfH[i] + Self.yMargin) {
                respawnColumn(i, initial: false)
            }
        }
        // Character flicker: reroll a few cells per frame.
        let flickerCount = max(1, (columnsCount * trail) / 40)
        for _ in 0..<flickerCount {
            let ci = Int.random(in: 0..<columnsCount)
            let cj = Int.random(in: 0..<trail)
            cellUV[ci][cj] = randomUV()
        }
    }

    /// Head world positions of columns near the given base plane --
    /// candidates for physics-character spawns (a stream "rains" onto the
    /// object surface when its head position lies within this window).
    func streamHeads(objectZ: Float, footprint: Float, yMin: Float, yMax: Float) -> [SIMD3<Float>] {
        guard columnsCount > 0 else { return [] }
        var out: [SIMD3<Float>] = []
        for i in 0..<columnsCount where abs(colX[i]) < footprint && abs(colZ[i] - objectZ) < footprint && colY[i] > yMin && colY[i] < yMax {
            out.append(SIMD3<Float>(colX[i], colY[i], colZ[i]))
        }
        return out
    }

    func collectInstances() -> [Glyph3DInstance] {
        guard columnsCount > 0 else { return [] }
        var out: [Glyph3DInstance] = []
        out.reserveCapacity(columnsCount * trail)
        let rightPad = SIMD4<Float>(rightVec.x, rightVec.y, rightVec.z, 0)
        let upPad = SIMD4<Float>(upVec.x, upVec.y, upVec.z, 0)
        for i in 0..<columnsCount {
            let halfH = colHalfH[i]
            for j in 0..<trail where !cellGap[i][j] {
                let y = colY[i] + Float(j) * cellH
                if y <= -(halfH + cellH) || y >= (halfH + cellH) { continue }
                let center = SIMD4<Float>(colX[i], y, colZ[i], 0)
                out.append(Glyph3DInstance(center: center, right: rightPad, up: upPad, color: cellColor[i][j], uv: cellUV[i][j]))
            }
        }
        return out
    }
}
