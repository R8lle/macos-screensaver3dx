import AppKit
import Metal
import MetalKit

/// Character set for the Matrix rain: katakana + alphanumeric + symbols.
/// Identical to the character selection in `savers/matrix_atlas.py`.
enum MatrixCharset {
    static let characters: [Character] = Array(
        "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ"
        + "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        + "0123456789"
        + "+-=<>[]{}#%&"
    )
}

/// A once-rendered bitmap of all characters ("sprite atlas"), used
/// afterwards as a Metal texture instead of drawing each character
/// individually every frame.
final class GlyphAtlas {
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let columns: Int
    let rows: Int
    let texture: MTLTexture
    private let charToIndex: [Character: Int]
    private let indexUV: [(u0: Float, v0: Float, u1: Float, v1: Float)]

    init?(device: MTLDevice, fontSize: CGFloat) {
        let chars = MatrixCharset.characters
        var charToIndex: [Character: Int] = [:]
        for (i, ch) in chars.enumerated() { charToIndex[ch] = i }

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .init(0.2))
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]

        var maxW: CGFloat = 0
        var maxH: CGFloat = 0
        for ch in chars {
            let size = String(ch).size(withAttributes: attrs)
            maxW = max(maxW, size.width)
            maxH = max(maxH, size.height)
        }

        let cellW = max(10.0, maxW + 3.0)
        let cellH = max(12.0, maxH + 4.0)
        let cols = 16
        let rowCount = (chars.count + cols - 1) / cols
        let atlasW = Int(CGFloat(cols) * cellW)
        let atlasH = Int(rowCount * Int(cellH))

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: atlasW,
            pixelsHigh: atlasH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else { return nil }

        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = ctx
        var indexUV: [(Float, Float, Float, Float)] = []
        NSColor.black.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: atlasW, height: atlasH))
        for (index, ch) in chars.enumerated() {
            let col = index % cols
            let row = index / cols
            let x = CGFloat(col) * cellW + 1.0
            let y = CGFloat(row) * cellH + 2.0
            String(ch).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            let u0 = Float(CGFloat(col) * cellW / CGFloat(atlasW))
            let u1 = Float(CGFloat(col + 1) * cellW / CGFloat(atlasW))
            let v0 = Float(CGFloat(row) * cellH / CGFloat(atlasH))
            let v1 = Float(CGFloat(row + 1) * cellH / CGFloat(atlasH))
            indexUV.append((u0, v0, u1, v1))
        }
        NSGraphicsContext.current = previous

        guard let cgImage = bitmap.cgImage else { return nil }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.flippedVertically,
        ]
        guard let texture = try? loader.newTexture(cgImage: cgImage, options: options) else { return nil }

        self.cellWidth = cellW
        self.cellHeight = cellH
        self.columns = cols
        self.rows = rowCount
        self.texture = texture
        self.charToIndex = charToIndex
        self.indexUV = indexUV.map { (u0: $0.0, v0: $0.1, u1: $0.2, v1: $0.3) }
    }

    func uv(for char: Character) -> (u0: Float, v0: Float, u1: Float, v1: Float) {
        let idx = charToIndex[char] ?? 0
        return indexUV[idx]
    }

    static func randomChar() -> Character {
        MatrixCharset.characters.randomElement()!
    }
}
