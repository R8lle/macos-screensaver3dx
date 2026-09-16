import AppKit
import Metal
import MetalKit
import ScreenSaver

/// Renders the built .saver for a few seconds and writes picker thumbnails.
/// Usage: capture_thumbnail <Matrix3DSaverX.saver> <output-dir>
///
/// Uses whatever ScreenSaverDefaults are currently stored. For a catalog
/// shot, temporarily set model=ralle_logo, variant=matrix3d_object,
/// rain_streams=360, physics_glyphs=0, all object_spin_*=false, and a
/// slight tilt (about X=10°, Y=28°) so R@lle faces the camera, then restore.
/// Do not capture with Y-spin on: after a few seconds the logo is edge-on.

func resizedPNG(from image: NSImage, width: Int, height: Int) -> Data? {
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
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.draw(
        in: NSRect(x: 0, y: 0, width: width, height: height),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func write(_ data: Data, to path: String) {
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote", path)
}

func findMTKView(in view: NSView) -> MTKView? {
    if let mtk = view as? MTKView { return mtk }
    for sub in view.subviews {
        if let found = findMTKView(in: sub) { return found }
    }
    return nil
}

func captureMetalFrame(_ mtkView: MTKView) -> NSImage? {
    mtkView.draw()
    guard
        let drawable = mtkView.currentDrawable,
        let device = mtkView.device,
        let queue = device.makeCommandQueue()
    else { return nil }

    let src = drawable.texture
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: src.width,
        height: src.height,
        mipmapped: false
    )
    desc.storageMode = .shared
    desc.usage = [.shaderRead, .shaderWrite]
    guard
        let dest = device.makeTexture(descriptor: desc),
        let commandBuffer = queue.makeCommandBuffer(),
        let blit = commandBuffer.makeBlitCommandEncoder()
    else { return nil }

    blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
              to: dest, destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    let bytesPerRow = src.width * 4
    var bytes = [UInt8](repeating: 0, count: src.height * bytesPerRow)
    dest.getBytes(
        &bytes,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, src.width, src.height),
        mipmapLevel: 0
    )

    // Metal BGRA, bottom-left vs AppKit top-left: flip vertically while swapping BGRA→RGBA.
    var rgba = [UInt8](repeating: 0, count: bytes.count)
    for y in 0..<src.height {
        let srcRow = (src.height - 1 - y) * bytesPerRow
        let dstRow = y * bytesPerRow
        for x in 0..<src.width {
            let si = srcRow + x * 4
            let di = dstRow + x * 4
            rgba[di] = bytes[si + 2]
            rgba[di + 1] = bytes[si + 1]
            rgba[di + 2] = bytes[si]
            rgba[di + 3] = bytes[si + 3]
        }
    }

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: src.width,
        pixelsHigh: src.height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: bytesPerRow,
        bitsPerPixel: 32
    ) else { return nil }
    memcpy(rep.bitmapData!, rgba, rgba.count)
    let image = NSImage(size: NSSize(width: src.width, height: src.height))
    image.addRepresentation(rep)
    return image
}

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: capture_thumbnail <Matrix3DSaverX.saver> <output-dir>\n", stderr)
    exit(1)
}

let saverPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

guard let bundle = Bundle(path: saverPath), bundle.load() else {
    fputs("Could not load \(saverPath)\n", stderr)
    exit(1)
}
guard let cls = bundle.principalClass as? ScreenSaverView.Type else {
    fputs("No ScreenSaverView principal class in \(saverPath)\n", stderr)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

let captureSize = NSSize(width: 1280, height: 800)
let frame = NSRect(origin: .zero, size: captureSize)
guard let view = cls.init(frame: frame, isPreview: false) else {
    fputs("Could not instantiate ScreenSaverView\n", stderr)
    exit(1)
}

let window = NSWindow(
    contentRect: frame,
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
window.isReleasedWhenClosed = false
window.backgroundColor = .black
window.isOpaque = true
window.setFrameOrigin(NSPoint(x: 120, y: 120))
window.contentView = view
window.orderFrontRegardless()
view.startAnimation()

print("warming up renderer…")
RunLoop.main.run(until: Date().addingTimeInterval(4.0))

let shotPath = "\(outDir)/window-capture.png"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let shot = Process()
shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
shot.arguments = ["-l", String(window.windowNumber), "-o", "-x", shotPath]
try! shot.run()
shot.waitUntilExit()

view.stopAnimation()
window.orderOut(nil)

var captured: NSImage?
if shot.terminationStatus == 0, let disk = NSImage(contentsOfFile: shotPath), disk.size.width > 10 {
    captured = disk
    print("window screenshot \(Int(disk.size.width))x\(Int(disk.size.height))")
} else if let mtkView = findMTKView(in: view), let metal = captureMetalFrame(mtkView) {
    captured = metal
    print("metal fallback \(Int(metal.size.width))x\(Int(metal.size.height))")
}

guard let captured else {
    fputs("Capture failed (screencapture status \(shot.terminationStatus))\n", stderr)
    exit(1)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

guard
    let png1x = resizedPNG(from: captured, width: 90, height: 58),
    let png2x = resizedPNG(from: captured, width: 180, height: 116)
else {
    fputs("Resize failed\n", stderr)
    exit(1)
}

write(png1x, to: "\(outDir)/thumbnail.png")
write(png2x, to: "\(outDir)/thumbnail@2x.png")
write(resizedPNG(from: captured, width: 1280, height: 800)!, to: "\(outDir)/thumbnail-full.png")
