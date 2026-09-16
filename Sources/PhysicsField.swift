import simd

private enum PhysicsGlyphState {
    case falling, resting, sliding
}

private final class PhysicsGlyph {
    var pos: SIMD3<Float>
    var vel: SIMD3<Float>
    var uv: SIMD4<Float>
    var color: SIMD4<Float>
    var state: PhysicsGlyphState = .falling
    var localPos: SIMD3<Float>?
    var localNormal: SIMD3<Float>?
    var restY: Float = 0
    var alive = true
    // Only visible after the first object hit: the approach from above
    // shouldn't appear as a single falling character (only rain is visible up top).
    var hit = false
    var bounces = 0

    init(pos: SIMD3<Float>, vel: SIMD3<Float>, uv: SIMD4<Float>, color: SIMD4<Float>) {
        self.pos = pos
        self.vel = vel
        self.uv = uv
        self.color = color
    }
}

/// Real point physics for Matrix characters on the rotating 3D object.
///
/// A bounded pool of characters falls under gravity, bounces off the
/// surface, and slides down the slope as the tilt increases, until it
/// falls out of frame at the bottom. Collision uses the `GpuRaycaster`:
/// the camera ray at the projected character position returns the
/// frontmost surface + normal.
///
/// `STICK_TO_SURFACE` is deliberately disabled (characters never stay put
/// anywhere, only falling<->sliding); the RESTING state therefore exists
/// only structurally (for a possible later change).
final class PhysicsField {
    private(set) var width: Float
    private(set) var height: Float
    let preview: Bool
    private(set) var glyphHalfW: Float
    private(set) var glyphHalfH: Float
    let maxGlyphs: Int
    private var glyphs: [PhysicsGlyph] = []

    private static let up = SIMD3<Float>(0, 1, 0)
    private static let stickToSurface = false

    private static let gravity: Float = 2.6
    private static let spawnSpeedMin: Float = 0.5
    private static let spawnSpeedMax: Float = 1.0
    private static let restitution: Float = 0.26
    private static let tangentKeep: Float = 0.42
    private static let restSpeed: Float = 0.55
    private static let restCos: Float = 0.85
    private static let slideCos: Float = 0.72
    private static let slideFriction: Float = 1.9
    private static let climbTolerance: Float = 0.06
    private static let edgeFacing: Float = 0.16
    private static let contactBreak: Float = 0.09
    private static let contactDepth: Float = 0.15
    private static let overhangCos: Float = -0.05
    private static let bounceBudget = 2
    private static let carryRate: Float = 0.5
    private static let collisionSkin: Float = 0.05
    private static let glyphLift: Float = 0.018

    private static let streamFootprint: Float = 1.5
    private static let streamYMin: Float = -2.6
    private static let streamYMax: Float = 1.9
    private static let rayTopY: Float = 2.6
    private static let landTolerance: Float = 0.15
    private static let fillTime: Float = 0.5
    private static let spawnPerStreamMax: Float = 3.0
    private static let despawnMargin: Float = 0.25

    init(width: Float, height: Float, preview: Bool, glyphHalfW: Float, glyphHalfH: Float, maxGlyphs: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.preview = preview
        self.glyphHalfW = glyphHalfW
        self.glyphHalfH = glyphHalfH
        self.maxGlyphs = max(0, maxGlyphs)
    }

    func resize(width: Float, height: Float) {
        let w = max(1, width), h = max(1, height)
        if abs(self.width - w) < 1 && abs(self.height - h) < 1 { return }
        self.width = w
        self.height = h
    }

    func setGlyphSize(halfW: Float, halfH: Float) {
        glyphHalfW = halfW
        glyphHalfH = halfH
    }

    private func randomUV(atlas: GlyphAtlas) -> SIMD4<Float> {
        let uv = atlas.uv(for: GlyphAtlas.randomChar())
        return SIMD4<Float>(uv.u0, uv.v0, uv.u1, uv.v1)
    }

    private func frustumHalfHeight(_ z: Float) -> Float {
        max(0.1, (Scene.cameraEye.z - z) * tan(Scene.fovY * 0.5))
    }

    private func downslope(_ n: SIMD3<Float>) -> SIMD3<Float> {
        let gVec = SIMD3<Float>(0, -Self.gravity, 0)
        let tangent = gVec - dot(gVec, n) * n
        let norm = length(tangent)
        return norm < 1e-6 ? .zero : tangent / norm
    }

    private func spawnFromContact(_ hit: RayHit, atlas: GlyphAtlas) {
        let n = normalize(hit.normal)
        let vIn = SIMD3<Float>(0, -Float.random(in: Self.spawnSpeedMin...Self.spawnSpeedMax), 0)
        let vn = dot(vIn, n)
        let vTangent = vIn - vn * n
        let vel = vTangent * Self.tangentKeep - n * (vn * Self.restitution)
        var t1 = cross(n, Self.up)
        t1 = length(t1) < 1e-6 ? SIMD3<Float>(1, 0, 0) : normalize(t1)
        let t2 = cross(n, t1)
        let jitter = t1 * Float.random(in: -0.03...0.03) + t2 * Float.random(in: -0.03...0.03)
        let color = Float.random(in: 0..<1) < 0.5 ? MatrixPalette.head : MatrixPalette.green[MatrixPalette.green.count - 1]
        let g = PhysicsGlyph(
            pos: hit.position + n * Self.glyphLift + jitter,
            vel: vel,
            uv: randomUV(atlas: atlas),
            color: SIMD4<Float>(color.0, color.1, color.2, color.3)
        )
        g.hit = true
        g.bounces = 1 // the spawn splash is the first bounce
        glyphs.append(g)
    }

    // MARK: - Simulation

    func update(dt: Float, objectZ: Float, spin: SIMD3<Float>, tiltDegrees: SIMD3<Float>, raycaster: GpuRaycaster?, rain: WorldRain?, atlas: GlyphAtlas) {
        let rot3 = Scene.rotationMatrix3x3(spin: spin, tiltDegrees: tiltDegrees)
        let shift = SIMD3<Float>(0, 0, objectZ)

        // 1) RESTING characters move along with the rotation in local frame
        //    (STICK_TO_SURFACE=false -> this state is never actually reached,
        //    carried over 1:1 structurally).
        for g in glyphs where g.state == .resting {
            guard let lp = g.localPos, let ln = g.localNormal else { continue }
            g.pos = Scene.localToWorld(lp, rotation3x3: rot3) + shift
            let worldN = normalize(Scene.localToWorld(ln, rotation3x3: rot3))
            if dot(worldN, Self.up) < Self.slideCos || g.pos.y > g.restY + Self.climbTolerance {
                g.state = .sliding
                g.vel = downslope(worldN) * 0.05
                g.localPos = nil
                g.localNormal = nil
            }
        }

        // 2) Bundle collision queries for FALLING/SLIDING plus stream heads
        //    (one shared GPU batch per query kind).
        var queries: [(Float, Float)] = []
        var queryIndex: [Int] = []
        for (idx, g) in glyphs.enumerated() where g.state == .falling || g.state == .sliding {
            if let sp = Scene.projectWorldToScreen(g.pos, width: width, height: height, objectZ: objectZ) {
                queries.append(sp)
                queryIndex.append(idx)
            }
        }

        var heads: [SIMD3<Float>] = []
        let wantStreams = rain != nil && raycaster != nil && glyphs.count < maxGlyphs
        if wantStreams, let rain {
            heads = rain.streamHeads(objectZ: objectZ, footprint: Self.streamFootprint, yMin: Self.streamYMin, yMax: Self.streamYMax)
        }

        var hits: [Int64: RayHit] = [:]
        if let raycaster, !queries.isEmpty || !heads.isEmpty {
            raycaster.beginFrame(screenWidth: width, screenHeight: height, objectZ: objectZ, spin: spin, tiltDegrees: tiltDegrees)
            if !queries.isEmpty {
                hits = raycaster.castBatch(queries)
            }
        }

        var hitFor: [Int: RayHit] = [:]
        for (localI, glyphIdx) in queryIndex.enumerated() {
            let sp = queries[localI]
            if let h = hits[GpuRaycaster.packKey(Int(sp.0), Int(sp.1))] {
                hitFor[glyphIdx] = h
            }
        }

        // 3) A stream sweeping past the top edge -> new physics characters at
        //    the point of impact. Vertical rays from above return the
        //    topmost hit per (x, z); the column "rains" as long as its
        //    vertical extent intersects this height.
        if !heads.isEmpty, let rain, let raycaster {
            let trailExtent = Float(rain.trail) * rain.cellH
            var origins = heads
            for i in origins.indices { origins[i].y = Self.rayTopY }
            let directions = [SIMD3<Float>](repeating: SIMD3<Float>(0, -1, 0), count: origins.count)
            let surfaces = raycaster.castWorldRays(origins: origins, directions: directions)
            var eligible: [RayHit] = []
            for k in 0..<heads.count {
                guard let surf = surfaces[k] else { continue }
                let headY = heads[k].y
                let streamTop = headY + trailExtent
                if headY - Self.landTolerance <= surf.position.y && surf.position.y <= streamTop {
                    eligible.append(surf)
                }
            }
            let deficit = maxGlyphs - glyphs.count
            if deficit > 0 && !eligible.isEmpty {
                let perStream = min(Self.spawnPerStreamMax, (Float(deficit) * dt / Self.fillTime) / Float(eligible.count))
                for surf in eligible {
                    if glyphs.count >= maxGlyphs { break }
                    var count = Int(perStream)
                    if Float.random(in: 0..<1) < perStream - Float(count) { count += 1 }
                    for _ in 0..<count {
                        if glyphs.count >= maxGlyphs { break }
                        spawnFromContact(surf, atlas: atlas)
                    }
                }
            }
        }

        // 4) Integrate per state.
        for (idx, g) in glyphs.enumerated() {
            switch g.state {
            case .falling:
                updateFalling(g, dt: dt, hit: hitFor[idx], objectZ: objectZ, rot3: rot3)
            case .sliding:
                updateSliding(g, dt: dt, hit: hitFor[idx], objectZ: objectZ, rot3: rot3)
            case .resting:
                break
            }
            // Once a character falls out of the visible frame at the bottom
            // (depth-dependent frustum edge), it's gone for good.
            if g.pos.y < -(frustumHalfHeight(g.pos.z) + Self.despawnMargin) {
                g.alive = false
            }
        }
        glyphs.removeAll { !$0.alive }
    }

    private func updateFalling(_ g: PhysicsGlyph, dt: Float, hit: RayHit?, objectZ: Float, rot3: simd_float3x3) {
        g.vel.y -= Self.gravity * dt
        g.pos = g.pos + g.vel * dt

        guard let hit else { return }
        let n = normalize(hit.normal)

        let dGlyph = length(g.pos - Scene.cameraEye)
        let dHit = hit.distance
        if dGlyph < dHit - Self.collisionSkin { return } // still in front of the surface
        if dGlyph > dHit + Self.contactDepth { return }  // an occluding surface, not a real contact

        // Landing: snap onto the surface, but rate-limit the lift.
        var newPos = hit.position + n * Self.glyphLift
        let maxY = g.pos.y + Self.carryRate * dt
        if newPos.y > maxY { newPos.y = maxY }
        g.pos = newPos
        g.hit = true
        let vn = dot(g.vel, n)
        let vTangent = g.vel - vn * n
        let approach = max(0, -vn)

        if approach >= Self.restSpeed && g.bounces < Self.bounceBudget {
            g.bounces += 1
            g.vel = vTangent * Self.tangentKeep - n * (vn * Self.restitution)
            return
        }

        if dot(n, Self.up) <= Self.overhangCos {
            // Overhang: nothing supports the character -- push it off and keep falling.
            g.vel = vTangent + n * 0.15
            return
        }

        if Self.stickToSurface && dot(n, Self.up) >= Self.restCos && length(vTangent) < Self.restSpeed {
            makeResting(g, n: n, objectZ: objectZ, rot3: rot3)
            return
        }

        // Every further contact is a sliding contact.
        g.state = .sliding
        g.vel = vTangent * 0.8
        if g.vel.y > 0 { g.vel.y = 0 }
    }

    private func updateSliding(_ g: PhysicsGlyph, dt: Float, hit: RayHit?, objectZ: Float, rot3: simd_float3x3) {
        guard let hit else {
            g.state = .falling
            g.vel.y -= Self.gravity * dt
            g.pos = g.pos + g.vel * dt
            return
        }
        let n = normalize(hit.normal)
        let hitPos = hit.position

        // Contact window: the hit no longer spatially belongs to the
        // touched surface -> fall freely instead of snapping back.
        let separation = dot(g.pos - hitPos, n)
        if separation > Self.glyphLift + Self.contactBreak || separation < -Self.contactDepth {
            g.state = .falling
            g.vel.y -= Self.gravity * dt
            g.pos = g.pos + g.vel * dt
            return
        }

        if dot(n, Self.up) <= Self.overhangCos {
            g.state = .falling
            g.vel = g.vel + n * 0.15
            g.vel.y -= Self.gravity * dt
            g.pos = g.pos + g.vel * dt
            return
        }

        // Receding edge: the surface is tilting away from the camera ->
        // switch to free fall instead of following the silhouette.
        let viewDir = normalize(Scene.cameraEye - hitPos)
        if dot(n, viewDir) < Self.edgeFacing {
            g.state = .falling
            g.vel.y -= Self.gravity * dt
            g.pos = g.pos + g.vel * dt
            return
        }

        let gVec = SIMD3<Float>(0, -Self.gravity, 0)
        let aTangent = gVec - dot(gVec, n) * n
        g.vel = g.vel + aTangent * dt
        g.vel = g.vel * max(0, 1 - Self.slideFriction * dt)
        if g.vel.y > 0 { g.vel.y = 0 } // Sliding never moves upward.
        g.pos = g.pos + g.vel * dt

        // Only pull back perpendicular to the surface (to compensate for
        // discretization drift); lift from the rotation is rate-limited.
        let preY = g.pos.y
        let normalOffset = dot(g.pos - hitPos, n) - Self.glyphLift
        g.pos = g.pos - n * normalOffset
        let maxY = preY + Self.carryRate * dt
        if g.pos.y > maxY { g.pos.y = maxY }

        let speed = length(g.vel)
        if speed < Self.restSpeed && dot(n, Self.up) >= Self.restCos && Self.stickToSurface {
            makeResting(g, n: n, objectZ: objectZ, rot3: rot3)
        }
    }

    private func makeResting(_ g: PhysicsGlyph, n: SIMD3<Float>, objectZ: Float, rot3: simd_float3x3) {
        let shifted = g.pos - SIMD3<Float>(0, 0, objectZ)
        g.localPos = Scene.worldToLocal(shifted, rotation3x3: rot3)
        g.localNormal = Scene.worldToLocal(n, rotation3x3: rot3)
        g.restY = g.pos.y
        g.vel = .zero
        g.state = .resting
    }

    // MARK: - Rendering

    /// Only characters that already bounced (`hit`) -- the approach from
    /// above stays invisible, only the rain columns are visible up top.
    func collectInstances(objectZ: Float) -> [Glyph3DInstance] {
        let visible = glyphs.filter(\.hit)
        guard !visible.isEmpty else { return [] }
        let (rightDir, upDir) = Scene.cameraBillboardAxes(objectZ: objectZ)
        let right = rightDir * glyphHalfW
        let up = upDir * glyphHalfH
        return visible.map { g in
            Glyph3DInstance(
                center: SIMD4<Float>(g.pos.x, g.pos.y, g.pos.z, 0),
                right: SIMD4<Float>(right.x, right.y, right.z, 0),
                up: SIMD4<Float>(up.x, up.y, up.z, 0),
                color: g.color,
                uv: g.uv
            )
        }
    }
}
