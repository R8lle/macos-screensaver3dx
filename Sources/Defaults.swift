import Foundation
import ScreenSaver

/// Slider values from the options dialog, persisted via ScreenSaverDefaults.
///
/// Independent sliders control amount, speed, and orientation -- each value
/// can be overridden per monitor (see `ScreenRegistry.scopedKey`); if a
/// per-monitor value is missing, it falls back to "all screens".
enum Defaults {
    /// Built bundle id (override at release via tools/local-signing.env).
    private static var moduleBundleIdentifier: String {
        Bundle(for: Matrix3DSaverView.self).bundleIdentifier
            ?? "de.r8lle.screensaver.matrix3dx"
    }

    /// Legacy `.saver` module id — kept for migration into the Appex store.
    static var legacyBundleIdentifier: String {
        let suffix = ".app.Extension"
        let id = moduleBundleIdentifier
        if id.hasSuffix(suffix) {
            return String(id.dropLast(suffix.count))
        }
        return id
    }

    /// Appex extension module id (prefs live under this name when built as APPEX).
    static var appexBundleIdentifier: String {
        let id = moduleBundleIdentifier
        if id.hasSuffix(".app.Extension") { return id }
        if id.hasSuffix(".app") { return id + ".Extension" }
        return id + ".app.Extension"
    }

    #if APPEX
    private static var bundleIdentifier: String { appexBundleIdentifier }
    #else
    private static var bundleIdentifier: String { legacyBundleIdentifier }
    #endif

    private static let prefsMigratedKey = "prefs_migrated_from_legacy_saver"
    private static var batchDepth = 0

    static var store: ScreenSaverDefaults {
        ScreenSaverDefaults(forModuleWithName: bundleIdentifier)!
    }

    /// Coalesce many preference writes into a single `synchronize()` (legacy `.saver`).
    /// Appex: never call `synchronize()` here — it deadlocks System Settings
    /// (host + extension both touch the same ScreenSaverDefaults domain on the
    /// main/XPC path), which leaves the Options sheet stuck open.
    static func performBatch(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        if batchDepth == 0 {
            synchronizeStore()
        }
    }

    static func synchronizeStore(_ defaults: ScreenSaverDefaults = store) {
        guard batchDepth == 0 else { return }
        #if APPEX
        // Rely on cfprefsd automatic flush; explicit synchronize deadlocks Settings.
        return
        #else
        defaults.synchronize()
        #endif
    }

    /// One-shot copy of ScreenSaverDefaults from the old `.saver` bundle id into
    /// the Appex extension id. Safe to call repeatedly; no-ops after success.
    static func migrateFromLegacyIfNeeded() {
        #if APPEX
        let dest = store
        guard !dest.bool(forKey: prefsMigratedKey) else { return }
        guard let source = ScreenSaverDefaults(forModuleWithName: legacyBundleIdentifier) else {
            dest.set(true, forKey: prefsMigratedKey)
            dest.synchronize()
            return
        }
        source.synchronize()
        if let dict = source.dictionaryRepresentation() as? [String: Any] {
            for (key, value) in dict {
                // Skip Apple/system noise; copy module keys (including scoped ones).
                if key.hasPrefix("Apple") || key.hasPrefix("NS") || key.hasPrefix("AK") { continue }
                if dest.object(forKey: key) == nil {
                    dest.set(value, forKey: key)
                }
            }
        }
        dest.set(true, forKey: prefsMigratedKey)
        dest.synchronize()
        #endif
    }

    // MARK: - Variant

    static let variantKey = "variant"
    static let defaultVariant = "matrix3d_object"
    static let variantChoices: [(id: String, displayName: String)] = [
        ("matrix3d_object", "Matrix 3D (mit Objekt)"),
        ("matrix3d_rain", "Matrix 3D (nur Regen)"),
        ("matrix_rain", "Matrix Rain (2D)"),
    ]
    private static let validVariants = Set(variantChoices.map(\.id))

    static func readVariant(screenID: Int32?) -> String {
        let d = store
        for key in [ScreenRegistry.scopedKey(variantKey, screenID: screenID), variantKey] {
            if let value = d.string(forKey: key), validVariants.contains(value) {
                return value
            }
        }
        return defaultVariant
    }

    static func writeVariant(_ variant: String, screenID: Int32?) {
        let resolved = validVariants.contains(variant) ? variant : defaultVariant
        let d = store
        d.set(resolved, forKey: ScreenRegistry.scopedKey(variantKey, screenID: screenID))
        d.synchronize()
    }

    // MARK: - Custom 3D text (overridable per monitor)

    static let customTextKey = "custom_text_string"
    static let customTextDefault = "Matrix"

    /// IMPORTANT: with two monitors that both use model ID
    /// "custom_text"/"custom_glb"/"custom_usdz", a new file/text selection
    /// for ONE screen would otherwise automatically change the other too if
    /// this value were global (unscoped) -- only the model-TYPE selection
    /// would then be scoped per screen, not the underlying file/text
    /// itself. So, like the other sliders, this is overridable per screen,
    /// falling back to the global "all screens" value.
    static func readCustomText(screenID: Int32?) -> String {
        let d = store
        for key in [ScreenRegistry.scopedKey(customTextKey, screenID: screenID), customTextKey] {
            if let value = d.string(forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return customTextDefault
    }

    static func writeCustomText(_ value: String, screenID: Int32?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = store
        d.set(trimmed.isEmpty ? customTextDefault : trimmed, forKey: ScreenRegistry.scopedKey(customTextKey, screenID: screenID))
        d.synchronize()
    }

    // MARK: - Custom GLB/USDZ file (overridable per monitor, see readCustomText)

    static let customGlbPathKey = "custom_glb_path"
    static let customGlbBookmarkKey = "custom_glb_bookmark"
    static let customUsdzPathKey = "custom_usdz_path"
    static let customUsdzBookmarkKey = "custom_usdz_bookmark"

    static func readCustomGlbPath(screenID: Int32?) -> String {
        let d = store
        for key in [ScreenRegistry.scopedKey(customGlbPathKey, screenID: screenID), customGlbPathKey] {
            if let value = d.string(forKey: key), !value.isEmpty { return value }
        }
        return ""
    }

    static func writeCustomGlbPath(_ value: String, screenID: Int32?) {
        let d = store
        d.set(value, forKey: ScreenRegistry.scopedKey(customGlbPathKey, screenID: screenID))
        d.synchronize()
    }

    /// Security-scoped bookmark for the chosen .glb file.
    ///
    /// Needed because the options dialog and the actually running
    /// (sandboxed) screensaver are DIFFERENT process instances: the file
    /// access granted via NSOpenPanel only applies to the presenting
    /// process and would otherwise be lost on the screensaver's next start
    /// (accessing the plain path string then fails even though the file
    /// exists). The bookmark makes the access reactivatable across
    /// processes.
    static func readCustomGlbBookmark(screenID: Int32?) -> Data? {
        let d = store
        for key in [ScreenRegistry.scopedKey(customGlbBookmarkKey, screenID: screenID), customGlbBookmarkKey] {
            if let value = d.data(forKey: key) { return value }
        }
        return nil
    }

    static func writeCustomGlbBookmark(_ value: Data?, screenID: Int32?) {
        let d = store
        let key = ScreenRegistry.scopedKey(customGlbBookmarkKey, screenID: screenID)
        if let value, !value.isEmpty {
            d.set(value, forKey: key)
        } else {
            d.removeObject(forKey: key)
        }
        d.synchronize()
    }

    static func readCustomUsdzPath(screenID: Int32?) -> String {
        let d = store
        for key in [ScreenRegistry.scopedKey(customUsdzPathKey, screenID: screenID), customUsdzPathKey] {
            if let value = d.string(forKey: key), !value.isEmpty { return value }
        }
        return ""
    }

    static func writeCustomUsdzPath(_ value: String, screenID: Int32?) {
        let d = store
        d.set(value, forKey: ScreenRegistry.scopedKey(customUsdzPathKey, screenID: screenID))
        d.synchronize()
    }

    /// Security-scoped bookmark for the chosen .usdz/.usd/.usda file
    /// (USDZ, like GLB, is self-contained -- a single-file bookmark
    /// suffices). See `readCustomGlbBookmark` for background.
    static func readCustomUsdzBookmark(screenID: Int32?) -> Data? {
        let d = store
        for key in [ScreenRegistry.scopedKey(customUsdzBookmarkKey, screenID: screenID), customUsdzBookmarkKey] {
            if let value = d.data(forKey: key) { return value }
        }
        return nil
    }

    static func writeCustomUsdzBookmark(_ value: Data?, screenID: Int32?) {
        let d = store
        let key = ScreenRegistry.scopedKey(customUsdzBookmarkKey, screenID: screenID)
        if let value, !value.isEmpty {
            d.set(value, forKey: key)
        } else {
            d.removeObject(forKey: key)
        }
        d.synchronize()
    }

    // MARK: - Amount sliders (full-screen values; preview scales proportionally)

    static let rainKey = "rain_streams"
    static let rainMin = 0, rainMax = 1800, rainDefault = 360

    static let physicsKey = "physics_glyphs"
    static let physicsMin = 0, physicsMax = 1000, physicsDefault = 180

    static let speedKey = "sim_speed_percent"
    static let speedMin = 10, speedMax = 200, speedDefault = 100

    /// World size of 3D rain / physics glyphs. 100 % is the current look.
    /// Perspective stays: nearby glyphs still look larger than distant ones.
    static let glyphSizeKey = "glyph_size_percent"
    static let glyphSizeMin = 50, glyphSizeMax = 200, glyphSizeDefault = 100

    static let tiltXKey = "object_tilt_x_deg"
    static let tiltYKey = "object_tilt_y_deg"
    static let tiltZKey = "object_tilt_z_deg"
    static let tiltMin = -90, tiltMax = 90, tiltDefault = 0

    static let spinXKey = "object_spin_x"
    static let spinYKey = "object_spin_y"
    static let spinZKey = "object_spin_z"
    static let spinDefault = true

    private static let previewScale = 0.4

    private static func readInt(_ key: String, default def: Int, lo: Int, hi: Int, screenID: Int32?) -> Int {
        let d = store
        for k in [ScreenRegistry.scopedKey(key, screenID: screenID), key] {
            if d.object(forKey: k) != nil {
                return min(hi, max(lo, d.integer(forKey: k)))
            }
        }
        return def
    }

    private static func writeInt(_ key: String, _ value: Int, lo: Int, hi: Int, screenID: Int32?) {
        let d = store
        d.set(min(hi, max(lo, value)), forKey: ScreenRegistry.scopedKey(key, screenID: screenID))
        d.synchronize()
    }

    private static func readBool(_ key: String, default def: Bool, screenID: Int32?) -> Bool {
        let d = store
        for k in [ScreenRegistry.scopedKey(key, screenID: screenID), key] {
            if d.object(forKey: k) != nil {
                return d.bool(forKey: k)
            }
        }
        return def
    }

    private static func writeBool(_ key: String, _ value: Bool, screenID: Int32?) {
        let d = store
        d.set(value, forKey: ScreenRegistry.scopedKey(key, screenID: screenID))
        d.synchronize()
    }

    static func readRainStreams(screenID: Int32?) -> Int {
        readInt(rainKey, default: rainDefault, lo: rainMin, hi: rainMax, screenID: screenID)
    }

    static func writeRainStreams(_ value: Int, screenID: Int32?) {
        writeInt(rainKey, value, lo: rainMin, hi: rainMax, screenID: screenID)
    }

    /// 0 means OFF -- don't clamp up to a minimum even in the preview.
    static func effectiveRainStreams(preview: Bool, screenID: Int32?) -> Int {
        let value = readRainStreams(screenID: screenID)
        if value <= 0 { return 0 }
        return preview ? max(8, Int((Double(value) * previewScale).rounded())) : value
    }

    static func readPhysicsGlyphs(screenID: Int32?) -> Int {
        readInt(physicsKey, default: physicsDefault, lo: physicsMin, hi: physicsMax, screenID: screenID)
    }

    static func writePhysicsGlyphs(_ value: Int, screenID: Int32?) {
        writeInt(physicsKey, value, lo: physicsMin, hi: physicsMax, screenID: screenID)
    }

    static func effectivePhysicsGlyphs(preview: Bool, screenID: Int32?) -> Int {
        let value = readPhysicsGlyphs(screenID: screenID)
        if value <= 0 { return 0 }
        return preview ? max(4, Int((Double(value) * previewScale).rounded())) : value
    }

    static func readSimSpeedPercent(screenID: Int32?) -> Int {
        readInt(speedKey, default: speedDefault, lo: speedMin, hi: speedMax, screenID: screenID)
    }

    static func writeSimSpeedPercent(_ value: Int, screenID: Int32?) {
        writeInt(speedKey, value, lo: speedMin, hi: speedMax, screenID: screenID)
    }

    static func readGlyphSizePercent(screenID: Int32?) -> Int {
        readInt(glyphSizeKey, default: glyphSizeDefault, lo: glyphSizeMin, hi: glyphSizeMax, screenID: screenID)
    }

    static func writeGlyphSizePercent(_ value: Int, screenID: Int32?) {
        writeInt(glyphSizeKey, value, lo: glyphSizeMin, hi: glyphSizeMax, screenID: screenID)
    }

    static func readObjectTiltXDeg(screenID: Int32?) -> Int {
        readInt(tiltXKey, default: tiltDefault, lo: tiltMin, hi: tiltMax, screenID: screenID)
    }
    static func writeObjectTiltXDeg(_ value: Int, screenID: Int32?) {
        writeInt(tiltXKey, value, lo: tiltMin, hi: tiltMax, screenID: screenID)
    }

    static func readObjectTiltYDeg(screenID: Int32?) -> Int {
        readInt(tiltYKey, default: tiltDefault, lo: tiltMin, hi: tiltMax, screenID: screenID)
    }
    static func writeObjectTiltYDeg(_ value: Int, screenID: Int32?) {
        writeInt(tiltYKey, value, lo: tiltMin, hi: tiltMax, screenID: screenID)
    }

    static func readObjectTiltZDeg(screenID: Int32?) -> Int {
        readInt(tiltZKey, default: tiltDefault, lo: tiltMin, hi: tiltMax, screenID: screenID)
    }
    static func writeObjectTiltZDeg(_ value: Int, screenID: Int32?) {
        writeInt(tiltZKey, value, lo: tiltMin, hi: tiltMax, screenID: screenID)
    }

    static func readObjectSpinX(screenID: Int32?) -> Bool {
        readBool(spinXKey, default: spinDefault, screenID: screenID)
    }
    static func writeObjectSpinX(_ value: Bool, screenID: Int32?) {
        writeBool(spinXKey, value, screenID: screenID)
    }

    static func readObjectSpinY(screenID: Int32?) -> Bool {
        readBool(spinYKey, default: spinDefault, screenID: screenID)
    }
    static func writeObjectSpinY(_ value: Bool, screenID: Int32?) {
        writeBool(spinYKey, value, screenID: screenID)
    }

    static func readObjectSpinZ(screenID: Int32?) -> Bool {
        readBool(spinZKey, default: spinDefault, screenID: screenID)
    }
    static func writeObjectSpinZ(_ value: Bool, screenID: Int32?) {
        writeBool(spinZKey, value, screenID: screenID)
    }

    /// Removes ALL monitor-specific overrides for a screen (including the
    /// base keys from other modules passed in via `extraKeys`, e.g. model).
    /// The monitor then falls back to the global "all screens" value for
    /// every setting again.
    static func resetScreenOverrides(screenID: Int32, extraKeys: [String] = []) {
        let d = store
        let baseKeys = [
            rainKey, physicsKey, speedKey, glyphSizeKey, tiltXKey, tiltYKey, tiltZKey, spinXKey, spinYKey, spinZKey, variantKey,
            customTextKey, customGlbPathKey, customGlbBookmarkKey, customUsdzPathKey, customUsdzBookmarkKey,
        ] + extraKeys
        for key in baseKeys {
            d.removeObject(forKey: ScreenRegistry.scopedKey(key, screenID: screenID))
        }
        d.synchronize()
    }

    // MARK: - Last active screen (cross-process hint)

    /// legacyScreenSaver.appex sometimes hosts the thumbnail/options and the
    /// large preview in TWO SEPARATE PROCESSES (confirmed empirically via
    /// PID logging) -- a simple in-memory static in Matrix3DSaverView is
    /// therefore NOT enough to tell ConfigureSheetController which screen is
    /// currently visible in System Settings when "Options…" is invoked from
    /// the (screenID-less) thumbnail while the large preview runs in a
    /// DIFFERENT process. ScreenSaverDefaults, on the other hand, is synced
    /// across processes (cfprefsd) -- hence this is additionally persisted
    /// here.
    private static let lastActiveScreenIDKey = "last_active_screen_id"

    static func writeLastActiveScreenID(_ screenID: Int32) {
        let d = store
        d.set(Int(screenID), forKey: lastActiveScreenIDKey)
        d.synchronize()
    }

    static func readLastActiveScreenID() -> Int32? {
        let d = store
        guard d.object(forKey: lastActiveScreenIDKey) != nil else { return nil }
        return Int32(d.integer(forKey: lastActiveScreenIDKey))
    }
}
