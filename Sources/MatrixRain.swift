import Foundation

/// A single falling character rectangle, ready for upload to the vertex
/// buffer (screen-space rain).
struct GlyphInstance {
    var x: Float
    var y: Float
    var u0: Float
    var v0: Float
    var u1: Float
    var v1: Float
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

/// Falling green palette + head character color (near white).
enum MatrixPalette {
    static let green: [(Float, Float, Float, Float)] = [
        (0.0, 0.45, 0.12, 0.35),
        (0.0, 0.62, 0.18, 0.50),
        (0.0, 0.78, 0.24, 0.68),
        (0.05, 0.90, 0.32, 0.85),
    ]
    static let head: (Float, Float, Float, Float) = (0.80, 1.0, 0.84, 1.0)
}

private struct MatrixCell {
    var char: Character = " "
    var charTimer: Int = 0
    var isGap: Bool = false
    var colorIdx: Int = 0
    var colorTimer: Int = 0
}

private final class MatrixColumn {
    var x: Float
    let lineHeight: Float
    var screenHeight: Float
    let preview: Bool
    var y: Float = 0
    var speed: Float = 10
    var spawnCooldown: Float = 0
    var cells: [MatrixCell] = []

    init(x: Float, lineHeight: Float, screenHeight: Float, preview: Bool) {
        self.x = x
        self.lineHeight = lineHeight
        self.screenHeight = screenHeight
        self.preview = preview
    }

    private func trailLength() -> Int {
        preview ? Int.random(in: 6...14) : Int.random(in: 10...26)
    }

    func spawnDrop(stagger: Bool, fillScreen: Bool = false) {
        let length = trailLength()
        cells = (0..<length).map { _ in
            let gap = Float.random(in: 0..<1) < (preview ? 0.10 : 0.14)
            return MatrixCell(
                char: gap ? " " : GlyphAtlas.randomChar(),
                charTimer: Int.random(in: 2...28),
                isGap: gap,
                colorIdx: Int.random(in: 0..<MatrixPalette.green.count),
                colorTimer: Int.random(in: 4...36)
            )
        }
        speed = preview ? Float.random(in: 9...18) : Float.random(in: 7...16)
        if fillScreen {
            let trailH = lineHeight * Float(length)
            let yTop = max(lineHeight, screenHeight - trailH * 0.05)
            let yBottom = screenHeight * 0.45
            y = Float.random(in: min(yBottom, yTop)...max(yBottom, yTop))
        } else if stagger {
            // AppKit convention: y > screenHeight = above the visible area,
            // falls in from above. max() guards against an inverted range
            // if screenHeight (e.g. shortly after the view is created,
            // before the real screen size is known) is still smaller than
            // lineHeight -- without this guard, Float.random(in:) crashes
            // with "lowerBound <= upperBound" and takes down the whole
            // screensaver host with it (no Options button anymore, since
            // the module as a whole failed to load).
            let upper = max(lineHeight, screenHeight * 0.95)
            y = screenHeight + Float.random(in: lineHeight...upper)
        } else {
            let upper = max(lineHeight, lineHeight * Float(length))
            y = screenHeight + Float.random(in: lineHeight...upper)
        }
        spawnCooldown = 0
    }

    func update(dt: Float) {
        if spawnCooldown > 0 {
            spawnCooldown = max(0, spawnCooldown - dt)
            return
        }
        y -= speed * dt * 58.0

        for i in cells.indices {
            if !cells[i].isGap {
                cells[i].charTimer -= 1
                if cells[i].charTimer <= 0 {
                    cells[i].char = GlyphAtlas.randomChar()
                    cells[i].charTimer = Int.random(in: 2...22)
                }
            }
            cells[i].colorTimer -= 1
            if cells[i].colorTimer <= 0 {
                cells[i].colorIdx = Int.random(in: 0..<MatrixPalette.green.count)
                cells[i].colorTimer = Int.random(in: 3...30)
            }
        }

        if y < -lineHeight {
            spawnCooldown = Float.random(in: 0.15...(preview ? 1.2 : 1.8))
            spawnDrop(stagger: true)
        }
    }

    func collectInstances(atlas: GlyphAtlas, into out: inout [GlyphInstance]) {
        for (index, cell) in cells.enumerated() {
            let cy = y + Float(index) * lineHeight
            if cy < -lineHeight || cy > screenHeight + lineHeight { continue }
            if cell.isGap { continue }
            let rgba = index == 0 ? MatrixPalette.head : MatrixPalette.green[cell.colorIdx % MatrixPalette.green.count]
            let uv = atlas.uv(for: cell.char)
            out.append(GlyphInstance(
                x: x, y: cy - lineHeight * 0.82,
                u0: uv.u0, v0: uv.v0, u1: uv.u1, v1: uv.v1,
                r: rgba.0, g: rgba.1, b: rgba.2, a: rgba.3
            ))
        }
    }
}

/// The whole Matrix rain: one column per character width across the full
/// screen width.
final class MatrixRainSimulation {
    private(set) var width: Float
    private(set) var height: Float
    let preview: Bool
    let atlas: GlyphAtlas
    private var columns: [MatrixColumn] = []

    init(width: Float, height: Float, preview: Bool, atlas: GlyphAtlas) {
        self.width = width
        self.height = height
        self.preview = preview
        self.atlas = atlas
        rebuildColumns(initial: true)
    }

    private func rebuildColumns(initial: Bool) {
        let charW = Float(atlas.cellWidth)
        let colCount = max(8, Int(width / charW) + 1)
        columns.removeAll(keepingCapacity: true)
        for index in 0..<colCount {
            let column = MatrixColumn(
                x: Float(index) * charW,
                lineHeight: Float(atlas.cellHeight),
                screenHeight: height,
                preview: preview
            )
            column.spawnDrop(stagger: true)
            if index < max(3, colCount / 3) {
                column.spawnCooldown = 0
            } else {
                column.spawnCooldown = Float.random(in: 0...(preview ? 0.6 : 0.8))
            }
            columns.append(column)
        }
    }

    /// Adjust column count to a new width, keep the rain currently running.
    func resize(width: Float, height: Float) {
        let width = max(1, width)
        let height = max(1, height)
        if abs(self.width - width) < 1 && abs(self.height - height) < 1 { return }

        let charW = Float(atlas.cellWidth)
        let newColCount = max(8, Int(width / charW) + 1)
        self.width = width
        self.height = height

        for column in columns { column.screenHeight = height }

        while columns.count < newColCount {
            let index = columns.count
            let column = MatrixColumn(
                x: Float(index) * charW,
                lineHeight: Float(atlas.cellHeight),
                screenHeight: height,
                preview: preview
            )
            column.spawnDrop(stagger: true)
            column.spawnCooldown = Float.random(in: 0...1.2)
            columns.append(column)
        }
        if columns.count > newColCount {
            columns.removeLast(columns.count - newColCount)
        }
        for (index, column) in columns.enumerated() {
            column.x = Float(index) * charW
        }
    }

    func update(dt: Float) {
        for column in columns { column.update(dt: dt) }
    }

    func collectInstances() -> [GlyphInstance] {
        var out: [GlyphInstance] = []
        out.reserveCapacity(columns.count * 18)
        for column in columns { column.collectInstances(atlas: atlas, into: &out) }
        return out
    }
}
