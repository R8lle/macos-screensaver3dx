import Cocoa

/// Small, STATIC coordinate system in the options dialog: shows how world
/// X/Y/Z are oriented relative to the screen (a help for the tilt sliders)
/// -- independent of the currently rotating 3D object, always the same
/// fixed world-axis orientation (see `Scene.cameraEye`: the camera looks
/// from +Z toward the origin, Y is the up axis).
final class AxisGizmoView: NSView {
    override var isFlipped: Bool { false }

    private func drawAxis(origin: NSPoint, dx: CGFloat, dy: CGFloat, color: NSColor, label: String) {
        color.setStroke()
        color.setFill()
        let end = NSPoint(x: origin.x + dx, y: origin.y + dy)
        let line = NSBezierPath()
        line.lineWidth = 2.0
        line.move(to: origin)
        line.line(to: end)
        line.stroke()

        let length = max(1.0, hypot(dx, dy))
        let ux = dx / length, uy = dy / length
        let px = -uy, py = ux
        let head: CGFloat = 7.0
        let left = NSPoint(x: end.x - ux * head + px * head * 0.5, y: end.y - uy * head + py * head * 0.5)
        let right = NSPoint(x: end.x - ux * head - px * head * 0.5, y: end.y - uy * head - py * head * 0.5)
        let arrow = NSBezierPath()
        arrow.move(to: end)
        arrow.line(to: left)
        arrow.line(to: right)
        arrow.close()
        arrow.fill()

        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11.0), .foregroundColor: color]
        let labelPoint = NSPoint(x: end.x + ux * 10 - 5, y: end.y + uy * 10 - 6)
        (label as NSString).draw(at: labelPoint, withAttributes: attrs)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 8.0, yRadius: 8.0)
        NSColor.controlBackgroundColor.setFill()
        bg.fill()
        NSColor.separatorColor.setStroke()
        bg.lineWidth = 1.0
        bg.stroke()

        let origin = NSPoint(x: bounds.width * 0.42, y: bounds.height * 0.38)
        // X: to the right (red), Y: upward (green), Z: diagonally forward-
        // down toward the viewer, shorter/perspective-compressed (blue) --
        // the same viewing direction as usual in Blender/Maya axis widgets.
        drawAxis(origin: origin, dx: 30, dy: 0, color: .systemRed, label: "X")
        drawAxis(origin: origin, dx: 0, dy: 32, color: .systemGreen, label: "Y")
        drawAxis(origin: origin, dx: -20, dy: -16, color: .systemBlue, label: "Z")
    }
}
