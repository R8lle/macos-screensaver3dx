import AppKit

func makeRep(width: Int, height: Int, landscape: Bool) -> NSBitmapImageRep {
    let size = CGSize(width: width, height: height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor.black.setFill()
    NSRect(origin: .zero, size: size).fill()

    let cols = max(1, width / 8)
    for c in 0..<cols {
        var seed = UInt64((c &* 1103515245 &+ 12345) & 0x7fffffff)
        let x = CGFloat(c) * (size.width / CGFloat(cols)) + 2
        var y = CGFloat(seed % UInt64(max(1, height)))
        while y < size.height + 40 {
            seed = seed &* 1103515245 &+ 12345
            let len = 6 + CGFloat(seed % 18)
            let bright = (seed % 5 == 0)
            (bright
                ? NSColor(calibratedRed: 0.7, green: 1, blue: 0.75, alpha: 1)
                : NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.12, alpha: 1)
            ).setFill()
            NSRect(x: x, y: y, width: 2, height: len).fill()
            y += len + CGFloat(8 + seed % 20)
        }
    }

    let bw = size.width * 0.72
    let bh = size.height * (landscape ? 0.46 : 0.36)
    let bx = (size.width - bw) / 2
    let by = (size.height - bh) / 2
    let badge = NSRect(x: bx, y: by, width: bw, height: bh)
    NSColor(calibratedRed: 0.0, green: 0.05, blue: 0.35, alpha: 1).setFill()
    badge.fill()
    let inset = badge.insetBy(dx: max(3, size.width * 0.02), dy: max(3, size.height * 0.02))
    NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
    inset.fill()

    let text = "R@lle" as NSString
    let fontSize = min(inset.height * 0.55, inset.width * 0.18)
    let font = NSFont.boldSystemFont(ofSize: fontSize)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.0, green: 0.04, blue: 0.32, alpha: 1)
    ]
    let ts = text.size(withAttributes: attrs)
    let tp = NSPoint(x: inset.midX - ts.width / 2, y: inset.midY - ts.height / 2)
    text.draw(at: tp, withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(width: Int, height: Int, landscape: Bool, to path: String) {
    let rep = makeRep(width: width, height: height, landscape: landscape)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote", path, "\(width)x\(height)")
}

let root = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

let tmp = URL(fileURLWithPath: "\(root)/build/AppIcon.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let map: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in map {
    writePNG(width: px, height: px, landscape: false,
             to: tmp.appendingPathComponent(name).path)
}
let icns = "\(root)/Resources/AppIcon.icns"
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", icns]
try! p.run()
p.waitUntilExit()
print("icns", p.terminationStatus, icns)
