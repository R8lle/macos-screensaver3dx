import AppKit

/// Monitor detection and per-screen keys for the screensaver defaults.
///
/// Every monitor has a stable display ID (CGDirectDisplayID, via
/// `NSScreen.deviceDescription()["NSScreenNumber"]`). Settings can be
/// stored per display ID; if a value is missing, it falls back to the
/// global "all screens" value (the base key without a suffix).
///
/// IMPORTANT: the CGDirectDisplayID is NOT stable for the built-in display
/// across the entire runtime -- on at least one test system, the ID of the
/// same (single) display changed spontaneously within a few seconds, even
/// though only ONE screen was online the whole time. That made the host
/// create a second full-screen instance. So: as soon as REALLY only one
/// screen is online, any monitor distinction is deliberately skipped
/// (screenID always nil = "all screens") -- that way the fluctuating ID
/// can no longer cause any harm. Only with REALLY multiple displays online
/// at the same time does the ID-based per-monitor logic come into play.
enum ScreenRegistry {
    static let allScreensLabel = "Alle Bildschirme (Standard)"

    /// Count of displays that are actually online right now (ground truth
    /// via CGGetOnlineDisplayList instead of NSScreen.screens(), since that
    /// reflects the actual hardware/compositor view). -1 on error.
    static func onlineDisplayCount() -> Int {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let err = CGGetOnlineDisplayList(16, &displays, &count)
        guard err == .success else { return -1 }
        return Int(count)
    }

    static func isSingleDisplay() -> Bool {
        let count = onlineDisplayCount()
        if count >= 0 { return count == 1 }
        return NSScreen.screens.count == 1
    }

    /// Base key for "all screens", otherwise with a display-ID suffix.
    static func scopedKey(_ baseKey: String, screenID: Int32?) -> String {
        guard let screenID else { return baseKey }
        return "\(baseKey)@\(screenID)"
    }

    static func screenID(for screen: NSScreen?) -> Int32? {
        guard let screen else { return nil }
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return number.int32Value
    }

    /// (Display ID, name) per monitor, in `NSScreen.screens()` order.
    /// Empty when there's only one screen -- then there's nothing to
    /// distinguish, "all screens" IS the one monitor (see the type
    /// documentation).
    static func listScreens() -> [(id: Int32?, name: String)] {
        guard !isSingleDisplay() else { return [] }
        return NSScreen.screens.map { screen in
            let sid = screenID(for: screen)
            let name = screen.localizedName.isEmpty ? "Bildschirm \(sid.map(String.init) ?? "?")" : screen.localizedName
            return (sid, name)
        }
    }

    /// Display ID by the view's frame size in points (fallback, in case the
    /// window isn't assigned to a screen yet). nil as soon as only one
    /// screen is online, regardless of whether its CGDirectDisplayID has
    /// changed since the last call.
    static func screenID(forFrameSize size: CGSize) -> Int32? {
        guard !isSingleDisplay() else { return nil }
        guard size.width > 1, size.height > 1 else { return nil }
        for screen in NSScreen.screens {
            let f = screen.frame
            if abs(f.width - size.width) < 4 && abs(f.height - size.height) < 4 {
                return screenID(for: screen)
            }
        }
        return nil
    }

    /// Display ID of the monitor the view is on (nil when unknown or only
    /// one screen is online). Preview instances must NEVER be allowed to
    /// get assigned a monitor this way (see Matrix3DSaverView.swift) --
    /// their window belongs to System Settings, not a real screen.
    static func screenID(for view: NSView) -> Int32? {
        guard !isSingleDisplay() else { return nil }
        let bySize = screenID(forFrameSize: view.frame.size)
        if let window = view.window {
            let byWindow = screenID(for: window.screen)
            if let byWindow, let bySize, byWindow != bySize {
                return bySize
            }
            if let byWindow {
                return byWindow
            }
        }
        return bySize
    }

    private static func screen(matchingFrameSize size: CGSize) -> NSScreen? {
        guard size.width > 1, size.height > 1 else { return nil }
        return NSScreen.screens.first { abs($0.frame.width - size.width) < 4 && abs($0.frame.height - size.height) < 4 }
    }

    /// Backing scale factor (1x/2x/3x) of the monitor the view is
    /// (presumably) displayed on -- independent of the preview restriction
    /// in `screenID(for:)`: this is only about render resolution, not
    /// settings scoping. Without this factor, glyphs on a Retina screen
    /// (2x) would look half the size compared to a 1x monitor, since Metal/
    /// the drawable works in pixels rather than points.
    static func backingScale(for view: NSView) -> Float {
        if let scale = view.window?.backingScaleFactor { return Float(scale) }
        if let scale = screen(matchingFrameSize: view.frame.size)?.backingScaleFactor { return Float(scale) }
        return Float(NSScreen.main?.backingScaleFactor ?? 2.0)
    }
}
