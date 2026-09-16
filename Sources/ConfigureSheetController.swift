import Cocoa
import UniformTypeIdentifiers

/// Content view with the origin at the top-left (like AppKit's standard
/// layout in most other UI toolkits) -- avoids having to convert every Y
/// coordinate from bottom-up.
private final class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
}

/// Options window (the "Options…" button in System Settings).
///
/// Screen selection + reset, variant, 3D model (four bundled models, custom
/// 3D text, custom GLB/USDZ file including file dialog + security-scoped
/// bookmark), rain/physics/speed sliders, tilt + rotation axes, axis
/// diagram.
final class ConfigureSheetController: NSObject, NSWindowDelegate {
    /// Host window for legacy `.saver` sheet presentation; nil when content is
    /// hosted by the Appex `ScreenSaverConfigurationViewController`.
    let window: NSWindow?
    /// Content root (also used as configuration VC `view` in Appex).
    let contentView: NSView
    var contentSize: NSSize { contentView.bounds.size }
    weak var owner: Matrix3DSaverView?
    /// Appex: dismiss via configuration VC (never `close()` the Settings window).
    var onDismiss: (() -> Void)?

    private var screenIDs: [Int32?] = [nil]
    private let screenPopup: NSPopUpButton
    private let resetScopeButton: NSButton
    private let variantPopup: NSPopUpButton
    private let modelPopup: NSPopUpButton
    private let textLabel: NSTextField
    private let textField: NSTextField

    private let glbLabel: NSTextField
    private let glbPathField: NSTextField
    private let glbButton: NSButton
    private var glbPath = ""
    private var glbBookmark: Data?
    private let usdzLabel: NSTextField
    private let usdzPathField: NSTextField
    private let usdzButton: NSButton
    private var usdzPath = ""
    private var usdzBookmark: Data?

    private let rainSlider: NSSlider
    private let rainValue: NSTextField
    private let physSlider: NSSlider
    private let physValue: NSTextField
    private let glyphSizeSlider: NSSlider
    private let glyphSizeValue: NSTextField
    private let speedSlider: NSSlider
    private let speedValue: NSTextField

    private let tiltXSlider: NSSlider
    private let tiltXValue: NSTextField
    private let tiltYSlider: NSSlider
    private let tiltYValue: NSTextField
    private let tiltZSlider: NSSlider
    private let tiltZValue: NSTextField

    private let spinXCheckbox: NSButton
    private let spinYCheckbox: NSButton
    private let spinZCheckbox: NSButton

    /// - Parameter ownsWindow: `true` for legacy `.saver` (`configureSheet`);
    ///   `false` for Appex configuration VC (content only — no private NSWindow).
    init(owner: Matrix3DSaverView?, ownsWindow: Bool = true) {
        self.owner = owner
        // 480x696, not the more spacious 620x526 the layout below would
        // otherwise want: under the Appex Options panel (WallpaperAgent
        // host), the window is NOT sized to whatever we report via
        // `preferredContentSize` -- it clips to some host-chosen width
        // instead, cutting off everything past ~460pt (reset button, axis
        // gizmo, OK/Cancel). 480 stays safely inside that. The extra height
        // is because the axis gizmo moved from beside the tilt sliders to
        // its own row below them -- no room for it beside them at the
        // narrower width.
        let width: CGFloat = 480
        let height: CGFloat = 696

        let content = FlippedContentView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        if ownsWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Matrix 3D X — Einstellungen"
            window.contentView = content
            self.window = window
        } else {
            self.window = nil
        }

        func label(_ text: String, _ frame: NSRect) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.frame = frame
            return field
        }

        // Screen + reset
        let screenLabel = label("Bildschirm:", NSRect(x: 20, y: 20, width: 110, height: 22))
        let screenPopup = NSPopUpButton(frame: NSRect(x: 140, y: 16, width: 190, height: 26), pullsDown: false)
        self.screenPopup = screenPopup
        let resetScopeButton = NSButton(frame: NSRect(x: 340, y: 16, width: 120, height: 26))
        resetScopeButton.title = "Zurücksetzen"
        resetScopeButton.bezelStyle = .rounded
        resetScopeButton.toolTip = "Entfernt die individuellen Einstellungen dieses Monitors — er folgt danach wieder „Alle Bildschirme“."
        self.resetScopeButton = resetScopeButton

        // Variant
        let variantLabel = label("Variante:", NSRect(x: 20, y: 60, width: 110, height: 22))
        let variantPopup = NSPopUpButton(frame: NSRect(x: 140, y: 56, width: 300, height: 26), pullsDown: false)
        self.variantPopup = variantPopup
        for choice in Defaults.variantChoices {
            variantPopup.addItem(withTitle: choice.displayName)
        }

        // Model
        let modelLabel = label("3D-Modell:", NSRect(x: 20, y: 100, width: 110, height: 22))
        let modelPopup = NSPopUpButton(frame: NSRect(x: 140, y: 96, width: 300, height: 26), pullsDown: false)
        self.modelPopup = modelPopup
        for spec in ModelRegistry.choices {
            modelPopup.addItem(withTitle: spec.displayName)
        }

        // Custom 3D text -- only visible/active when the model is "Custom 3D text".
        let textLabel = label("3D-Text:", NSRect(x: 20, y: 140, width: 110, height: 22))
        self.textLabel = textLabel
        let textField = NSTextField(frame: NSRect(x: 140, y: 136, width: 300, height: 26))
        textField.placeholderString = "Text fuer das 3D-Modell (z. B. Matrix)"
        self.textField = textField

        // Custom GLB file -- shares its row with the text field (never
        // visible at the same time, depends on the chosen model).
        let glbLabel = label("GLB-Datei:", NSRect(x: 20, y: 140, width: 110, height: 22))
        self.glbLabel = glbLabel
        let glbPathField = label("(keine Datei gewaehlt)", NSRect(x: 140, y: 140, width: 210, height: 20))
        glbPathField.font = .systemFont(ofSize: 11)
        glbPathField.textColor = .secondaryLabelColor
        glbPathField.lineBreakMode = .byTruncatingMiddle
        self.glbPathField = glbPathField
        let glbButton = NSButton(frame: NSRect(x: 360, y: 136, width: 100, height: 26))
        glbButton.title = "Wählen…"
        glbButton.bezelStyle = .rounded
        self.glbButton = glbButton

        // Custom USDZ file -- also shares the same row; USDZ, like GLB, is
        // self-contained (textures embedded), so a single-file dialog is
        // enough.
        let usdzLabel = label("USDZ-Datei:", NSRect(x: 20, y: 140, width: 110, height: 22))
        self.usdzLabel = usdzLabel
        let usdzPathField = label("(keine Datei gewaehlt)", NSRect(x: 140, y: 140, width: 210, height: 20))
        usdzPathField.font = .systemFont(ofSize: 11)
        usdzPathField.textColor = .secondaryLabelColor
        usdzPathField.lineBreakMode = .byTruncatingMiddle
        self.usdzPathField = usdzPathField
        let usdzButton = NSButton(frame: NSRect(x: 360, y: 136, width: 100, height: 26))
        usdzButton.title = "Wählen…"
        usdzButton.bezelStyle = .rounded
        self.usdzButton = usdzButton

        // Rain / physics / speed
        let rainLabel = label("Regen-Streams:", NSRect(x: 20, y: 176, width: 115, height: 22))
        let rainSlider = NSSlider(frame: NSRect(x: 140, y: 174, width: 250, height: 24))
        rainSlider.minValue = Double(Defaults.rainMin)
        rainSlider.maxValue = Double(Defaults.rainMax)
        rainSlider.isContinuous = true
        self.rainSlider = rainSlider
        let rainValue = label("0", NSRect(x: 398, y: 176, width: 58, height: 20))
        rainValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        self.rainValue = rainValue

        let physLabel = label("Physik-Zeichen:", NSRect(x: 20, y: 212, width: 115, height: 22))
        let physSlider = NSSlider(frame: NSRect(x: 140, y: 210, width: 250, height: 24))
        physSlider.minValue = Double(Defaults.physicsMin)
        physSlider.maxValue = Double(Defaults.physicsMax)
        physSlider.isContinuous = true
        self.physSlider = physSlider
        let physValue = label("0", NSRect(x: 398, y: 212, width: 58, height: 20))
        physValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        self.physValue = physValue

        let glyphSizeLabel = label("Buchstabengröße:", NSRect(x: 20, y: 248, width: 115, height: 22))
        let glyphSizeSlider = NSSlider(frame: NSRect(x: 140, y: 246, width: 250, height: 24))
        glyphSizeSlider.minValue = Double(Defaults.glyphSizeMin)
        glyphSizeSlider.maxValue = Double(Defaults.glyphSizeMax)
        glyphSizeSlider.isContinuous = true
        glyphSizeSlider.toolTip = "Skaliert die 3D-Matrix-Zeichen. Nahe Zeichen bleiben größer als ferne (Perspektive)."
        self.glyphSizeSlider = glyphSizeSlider
        let glyphSizeValue = label("100 %", NSRect(x: 398, y: 248, width: 58, height: 20))
        glyphSizeValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        self.glyphSizeValue = glyphSizeValue

        let speedLabel = label("Geschwindigkeit:", NSRect(x: 20, y: 284, width: 115, height: 22))
        let speedSlider = NSSlider(frame: NSRect(x: 140, y: 282, width: 250, height: 24))
        speedSlider.minValue = Double(Defaults.speedMin)
        speedSlider.maxValue = Double(Defaults.speedMax)
        speedSlider.isContinuous = true
        self.speedSlider = speedSlider
        let speedValue = label("100 %", NSRect(x: 398, y: 284, width: 58, height: 20))
        speedValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        self.speedValue = speedValue

        // Tilt per axis (visible once that axis's spin is deselected --
        // otherwise it just adds onto the ongoing rotation).
        var tiltSliders: [NSSlider] = []
        var tiltValues: [NSTextField] = []
        var tiltLabels: [NSTextField] = []
        for (row, axis) in ["X", "Y", "Z"].enumerated() {
            let y = 320 + row * 30
            let axisLabel = label("Neigung \(axis):", NSRect(x: 20, y: CGFloat(y), width: 115, height: 22))
            let slider = NSSlider(frame: NSRect(x: 140, y: CGFloat(y) - 2, width: 250, height: 24))
            slider.minValue = Double(Defaults.tiltMin)
            slider.maxValue = Double(Defaults.tiltMax)
            slider.isContinuous = true
            let value = label("0°", NSRect(x: 398, y: CGFloat(y), width: 58, height: 20))
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            tiltLabels.append(axisLabel)
            tiltSliders.append(slider)
            tiltValues.append(value)
        }
        (tiltXSlider, tiltYSlider, tiltZSlider) = (tiltSliders[0], tiltSliders[1], tiltSliders[2])
        (tiltXValue, tiltYValue, tiltZValue) = (tiltValues[0], tiltValues[1], tiltValues[2])

        // Small static axis diagram -- used to sit beside the tilt sliders
        // (x: 478), no longer fit there at the narrower 480pt window width
        // (see the comment on `width`/`height` above); now its own
        // centered row below them.
        let axisGizmo = AxisGizmoView(frame: NSRect(x: 195, y: 416, width: 90, height: 82))
        let axisCaption = label("Z: zum Betrachter", NSRect(x: 195, y: 498, width: 90, height: 16))
        axisCaption.font = .systemFont(ofSize: 9)
        axisCaption.textColor = .secondaryLabelColor
        axisCaption.alignment = .center

        // Rotate around: X/Y/Z
        let spinLabel = label("Rotation um:", NSRect(x: 20, y: 534, width: 115, height: 22))
        let spinXCheckbox = NSButton(checkboxWithTitle: "X", target: nil, action: nil)
        spinXCheckbox.frame = NSRect(x: 140, y: 534, width: 60, height: 22)
        let spinYCheckbox = NSButton(checkboxWithTitle: "Y", target: nil, action: nil)
        spinYCheckbox.frame = NSRect(x: 220, y: 534, width: 60, height: 22)
        let spinZCheckbox = NSButton(checkboxWithTitle: "Z", target: nil, action: nil)
        spinZCheckbox.frame = NSRect(x: 300, y: 534, width: 60, height: 22)
        self.spinXCheckbox = spinXCheckbox
        self.spinYCheckbox = spinYCheckbox
        self.spinZCheckbox = spinZCheckbox

        let bundle = Bundle(for: Matrix3DSaverView.self)
        let shortVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildVersion = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let buildLabel = label("Build: \(buildVersion) (\(shortVersion))", NSRect(x: 20, y: 578, width: 440, height: 18))
        buildLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        buildLabel.textColor = .secondaryLabelColor

        let year = Calendar.current.component(.year, from: Date())
        let copyrightLabel = label("© \(year) R@lle", NSRect(x: 20, y: 600, width: 440, height: 18))
        copyrightLabel.font = .systemFont(ofSize: 11)
        copyrightLabel.textColor = .secondaryLabelColor

        let okButton = NSButton(frame: NSRect(x: 270, y: 640, width: 90, height: 32))
        okButton.title = "OK"
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"

        let cancelButton = NSButton(frame: NSRect(x: 370, y: 640, width: 90, height: 32))
        cancelButton.title = "Abbrechen"
        cancelButton.bezelStyle = .rounded

        for view in [
            screenLabel, screenPopup, resetScopeButton,
            variantLabel, variantPopup,
            modelLabel, modelPopup,
            textLabel, textField,
            glbLabel, glbPathField, glbButton,
            usdzLabel, usdzPathField, usdzButton,
            rainLabel, rainSlider, rainValue,
            physLabel, physSlider, physValue,
            glyphSizeLabel, glyphSizeSlider, glyphSizeValue,
            speedLabel, speedSlider, speedValue,
        ] as [NSView] {
            content.addSubview(view)
        }
        for (l, s, v) in zip(zip(tiltLabels, tiltSliders), tiltValues).map({ ($0.0, $0.1, $1) }) {
            content.addSubview(l)
            content.addSubview(s)
            content.addSubview(v)
        }
        for view in [
            axisGizmo, axisCaption,
            spinLabel, spinXCheckbox, spinYCheckbox, spinZCheckbox,
            buildLabel, copyrightLabel,
            okButton, cancelButton,
        ] as [NSView] {
            content.addSubview(view)
        }

        self.contentView = content
        super.init()

        screenPopup.target = self
        screenPopup.action = #selector(screenChanged(_:))
        resetScopeButton.target = self
        resetScopeButton.action = #selector(resetScopeToAllScreens(_:))
        variantPopup.target = self
        variantPopup.action = #selector(variantChanged(_:))
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))
        glbButton.target = self
        glbButton.action = #selector(chooseGlbFile(_:))
        usdzButton.target = self
        usdzButton.action = #selector(chooseUsdzFile(_:))
        rainSlider.target = self
        rainSlider.action = #selector(rainSliderChanged(_:))
        physSlider.target = self
        physSlider.action = #selector(physSliderChanged(_:))
        glyphSizeSlider.target = self
        glyphSizeSlider.action = #selector(glyphSizeSliderChanged(_:))
        speedSlider.target = self
        speedSlider.action = #selector(speedSliderChanged(_:))
        tiltXSlider.target = self
        tiltXSlider.action = #selector(tiltXSliderChanged(_:))
        tiltYSlider.target = self
        tiltYSlider.action = #selector(tiltYSliderChanged(_:))
        tiltZSlider.target = self
        tiltZSlider.action = #selector(tiltZSliderChanged(_:))
        okButton.target = self
        okButton.action = #selector(okClicked(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))

        // The window has a native close button (.closable) -- closing via
        // that button bypasses okClicked/cancelClicked entirely, which used
        // to leave the owner's configOpen/sheetOwnerInstance bookkeeping
        // stuck "open" forever. windowWillClose below catches every close
        // path (button, red close button, host-initiated), not just ours;
        // configureSheetDidClose() is idempotent, so a redundant call from
        // endSheet() on top of this is harmless.
        window?.delegate = self

        populateScreenPopup()
        // With a known, concrete screen (see populateScreenPopup) it's
        // automatically the only entry -> index 0 is always correct.
        // Otherwise ALWAYS open on "All screens (default)" (also index 0),
        // NEVER auto-select another monitor -- an automatically
        // preselected monitor without the "all screens" alternative
        // otherwise leads to an unnoticed single-screen scope when opened
        // from the real full-screen instance.
        screenPopup.selectItem(at: 0)
        loadScope(selectedScope())
    }

    private func populateScreenPopup() {
        screenPopup.removeAllItems()
        // If the caller (large preview or real instance) is already tied
        // to a CONCRETE screen, System Settings itself has already decided
        // which monitor is currently being configured for (its own screen
        // selection in System Settings/wallpaper). In that case, offer
        // ONLY that one screen here -- "all screens" or a DIFFERENT
        // monitor wouldn't be what's currently visible, and switching to
        // it wouldn't work reliably anyway.
        //
        // IMPORTANT: per the diagnostic log, "Options…" is ALWAYS invoked
        // from the thumbnail (isPreview=true) -- which NEVER knows its
        // screen (owner?.screenID is always nil there). Fallback chain:
        //   1. Matrix3DSaverView.lastKnownRealScreenID -- if the large
        //      preview is running in the SAME process.
        //   2. Defaults.readLastActiveScreenID() -- ScreenSaverDefaults is
        //      synchronized across processes (cfprefsd); needed because,
        //      per the PID log, the thumbnail/options and the large
        //      preview can also run in TWO SEPARATE processes.
        //
        // Only for an unknown screen (no hint available, or only one
        // monitor present) does the full selection including "all
        // screens" remain.
        let lockedCandidate = owner?.screenID
            ?? Matrix3DSaverView.lastKnownRealScreenID
            ?? Defaults.readLastActiveScreenID()
        MeshAtlas.makeLogger(tag: "cfg-screen")(
            "populateScreenPopup: owner.screenID=\(owner?.screenID.map(String.init) ?? "nil") "
            + "lastKnownRealScreenID=\(Matrix3DSaverView.lastKnownRealScreenID.map(String.init) ?? "nil") "
            + "persisted=\(Defaults.readLastActiveScreenID().map(String.init) ?? "nil") "
            + "lockedCandidate=\(lockedCandidate.map(String.init) ?? "nil") "
            + "isSingleDisplay=\(ScreenRegistry.isSingleDisplay())"
        )
        if let lockedID = lockedCandidate, !ScreenRegistry.isSingleDisplay() {
            let name = ScreenRegistry.listScreens().first(where: { $0.id == lockedID })?.name
                ?? "Bildschirm \(lockedID)"
            screenIDs = [lockedID]
            screenPopup.addItem(withTitle: name)
            screenPopup.isEnabled = false
            return
        }
        screenPopup.isEnabled = true
        screenIDs = [nil]
        screenPopup.addItem(withTitle: ScreenRegistry.allScreensLabel)
        for (sid, name) in ScreenRegistry.listScreens() {
            screenIDs.append(sid)
            let suffix = sid.map { "  (ID \($0))" } ?? ""
            screenPopup.addItem(withTitle: name + suffix)
        }
    }

    private func selectedScope() -> Int32? {
        let index = screenPopup.indexOfSelectedItem
        guard index >= 0, index < screenIDs.count else { return nil }
        return screenIDs[index]
    }

    private func selectedVariant() -> String {
        let index = variantPopup.indexOfSelectedItem
        guard index >= 0, index < Defaults.variantChoices.count else { return Defaults.defaultVariant }
        return Defaults.variantChoices[index].id
    }

    private func selectedModel() -> String {
        let index = modelPopup.indexOfSelectedItem
        guard index >= 0, index < ModelRegistry.choices.count else { return ModelRegistry.defaultModelID }
        return ModelRegistry.choices[index].modelID
    }

    private func loadScope(_ screenID: Int32?) {
        let currentVariant = Defaults.readVariant(screenID: screenID)
        if let index = Defaults.variantChoices.firstIndex(where: { $0.id == currentVariant }) {
            variantPopup.selectItem(at: index)
        } else {
            variantPopup.selectItem(at: 0)
        }

        let currentModel = ModelRegistry.readModelID(screenID: screenID)
        if let index = ModelRegistry.choices.firstIndex(where: { $0.modelID == currentModel }) {
            modelPopup.selectItem(at: index)
        } else {
            modelPopup.selectItem(at: 0)
        }

        let rain = Defaults.readRainStreams(screenID: screenID)
        rainSlider.integerValue = rain
        rainValue.stringValue = "\(rain)"

        let phys = Defaults.readPhysicsGlyphs(screenID: screenID)
        physSlider.integerValue = phys
        physValue.stringValue = "\(phys)"

        let glyphSize = Defaults.readGlyphSizePercent(screenID: screenID)
        glyphSizeSlider.integerValue = glyphSize
        glyphSizeValue.stringValue = "\(glyphSize) %"

        let speed = Defaults.readSimSpeedPercent(screenID: screenID)
        speedSlider.integerValue = speed
        speedValue.stringValue = "\(speed) %"

        let tiltX = Defaults.readObjectTiltXDeg(screenID: screenID)
        tiltXSlider.integerValue = tiltX
        tiltXValue.stringValue = "\(tiltX)°"
        let tiltY = Defaults.readObjectTiltYDeg(screenID: screenID)
        tiltYSlider.integerValue = tiltY
        tiltYValue.stringValue = "\(tiltY)°"
        let tiltZ = Defaults.readObjectTiltZDeg(screenID: screenID)
        tiltZSlider.integerValue = tiltZ
        tiltZValue.stringValue = "\(tiltZ)°"

        spinXCheckbox.state = Defaults.readObjectSpinX(screenID: screenID) ? .on : .off
        spinYCheckbox.state = Defaults.readObjectSpinY(screenID: screenID) ? .on : .off
        spinZCheckbox.state = Defaults.readObjectSpinZ(screenID: screenID) ? .on : .off

        textField.stringValue = Defaults.readCustomText(screenID: screenID)
        glbPath = Defaults.readCustomGlbPath(screenID: screenID)
        glbBookmark = Defaults.readCustomGlbBookmark(screenID: screenID)
        updateGlbPathLabel()
        usdzPath = Defaults.readCustomUsdzPath(screenID: screenID)
        usdzBookmark = Defaults.readCustomUsdzBookmark(screenID: screenID)
        updateUsdzPathLabel()

        updateVariantControls()
        resetScopeButton.isEnabled = screenID != nil
    }

    private func updateVariantControls() {
        let is2D = selectedVariant() == "matrix_rain"
        for widget in [
            modelPopup as NSControl, rainSlider, physSlider, glyphSizeSlider,
            tiltXSlider, tiltYSlider, tiltZSlider,
            spinXCheckbox, spinYCheckbox, spinZCheckbox,
        ] {
            widget.isEnabled = !is2D
        }
        // The text field, GLB row, and USDZ row share the same row: only
        // the one matching the chosen model is visible.
        let model = selectedModel()
        let isTextModel = model == ModelRegistry.textModelID
        textLabel.isHidden = !isTextModel
        textField.isHidden = !isTextModel
        textField.isEnabled = !is2D && isTextModel
        let isGlbModel = model == ModelRegistry.glbModelID
        glbLabel.isHidden = !isGlbModel
        glbPathField.isHidden = !isGlbModel
        glbButton.isHidden = !isGlbModel
        glbButton.isEnabled = !is2D && isGlbModel
        let isUsdzModel = model == ModelRegistry.usdzModelID
        usdzLabel.isHidden = !isUsdzModel
        usdzPathField.isHidden = !isUsdzModel
        usdzButton.isHidden = !isUsdzModel
        usdzButton.isEnabled = !is2D && isUsdzModel
    }

    private func updateGlbPathLabel() {
        glbPathField.stringValue = glbPath.isEmpty
            ? "(keine Datei gewaehlt)"
            : (glbPath as NSString).lastPathComponent
        glbPathField.toolTip = glbPath.isEmpty ? nil : glbPath
    }

    private func updateUsdzPathLabel() {
        usdzPathField.stringValue = usdzPath.isEmpty
            ? "(keine Datei gewaehlt)"
            : (usdzPath as NSString).lastPathComponent
        usdzPathField.toolTip = usdzPath.isEmpty ? nil : usdzPath
    }

    /// Security-scoped bookmark, so the (separate, sandboxed) screensaver
    /// process can still access the file chosen here later -- see
    /// `Defaults.customGlbBookmark`.
    private func makeBookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    @objc private func chooseGlbFile(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Wählen"
        if let ut = UTType(filenameExtension: "glb") {
            panel.allowedContentTypes = [ut]
        }
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        glbPath = url.path
        glbBookmark = makeBookmark(url)
        updateGlbPathLabel()
    }

    @objc private func chooseUsdzFile(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Wählen"
        let uts = ["usdz", "usd", "usda"].compactMap { UTType(filenameExtension: $0) }
        if !uts.isEmpty {
            panel.allowedContentTypes = uts
        }
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        usdzPath = url.path
        usdzBookmark = makeBookmark(url)
        updateUsdzPathLabel()
    }

    @objc private func variantChanged(_ sender: NSPopUpButton) {
        updateVariantControls()
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        updateVariantControls()
    }

    @objc private func screenChanged(_ sender: NSPopUpButton) {
        loadScope(selectedScope())
    }

    @objc private func resetScopeToAllScreens(_ sender: NSButton) {
        guard let scope = selectedScope() else { return }
        Defaults.resetScreenOverrides(screenID: scope, extraKeys: [ModelRegistry.modelKey])
        loadScope(scope)
    }

    @objc private func rainSliderChanged(_ sender: NSSlider) {
        rainValue.stringValue = "\(sender.integerValue)"
    }

    @objc private func physSliderChanged(_ sender: NSSlider) {
        physValue.stringValue = "\(sender.integerValue)"
    }

    @objc private func glyphSizeSliderChanged(_ sender: NSSlider) {
        glyphSizeValue.stringValue = "\(sender.integerValue) %"
    }

    @objc private func speedSliderChanged(_ sender: NSSlider) {
        speedValue.stringValue = "\(sender.integerValue) %"
    }

    @objc private func tiltXSliderChanged(_ sender: NSSlider) {
        tiltXValue.stringValue = "\(sender.integerValue)°"
    }

    @objc private func tiltYSliderChanged(_ sender: NSSlider) {
        tiltYValue.stringValue = "\(sender.integerValue)°"
    }

    @objc private func tiltZSliderChanged(_ sender: NSSlider) {
        tiltZValue.stringValue = "\(sender.integerValue)°"
    }

    @objc private func okClicked(_ sender: NSButton) {
        let scope = selectedScope()
        let variant = selectedVariant()
        let model = selectedModel()
        let text = textField.stringValue
        let glbPath = self.glbPath
        let glbBookmark = self.glbBookmark
        let usdzPath = self.usdzPath
        let usdzBookmark = self.usdzBookmark
        let rain = rainSlider.integerValue
        let phys = physSlider.integerValue
        let glyphSize = glyphSizeSlider.integerValue
        let speed = speedSlider.integerValue
        let tiltX = tiltXSlider.integerValue
        let tiltY = tiltYSlider.integerValue
        let tiltZ = tiltZSlider.integerValue
        let spinX = spinXCheckbox.state == .on
        let spinY = spinYCheckbox.state == .on
        let spinZ = spinZCheckbox.state == .on

        let persist = {
            Defaults.writeVariant(variant, screenID: scope)
            ModelRegistry.writeModelID(model, screenID: scope)
            Defaults.writeCustomText(text, screenID: scope)
            Defaults.writeCustomGlbPath(glbPath, screenID: scope)
            Defaults.writeCustomGlbBookmark(glbBookmark, screenID: scope)
            Defaults.writeCustomUsdzPath(usdzPath, screenID: scope)
            Defaults.writeCustomUsdzBookmark(usdzBookmark, screenID: scope)
            Defaults.writeRainStreams(rain, screenID: scope)
            Defaults.writePhysicsGlyphs(phys, screenID: scope)
            Defaults.writeGlyphSizePercent(glyphSize, screenID: scope)
            Defaults.writeSimSpeedPercent(speed, screenID: scope)
            Defaults.writeObjectTiltXDeg(tiltX, screenID: scope)
            Defaults.writeObjectTiltYDeg(tiltY, screenID: scope)
            Defaults.writeObjectTiltZDeg(tiltZ, screenID: scope)
            Defaults.writeObjectSpinX(spinX, screenID: scope)
            Defaults.writeObjectSpinY(spinY, screenID: scope)
            Defaults.writeObjectSpinZ(spinZ, screenID: scope)
        }

        #if APPEX
        // Dismiss first (sample pattern). Prefs after — never synchronize on
        // the button stack or Settings freezes with the sheet still open.
        endSheet()
        DispatchQueue.global(qos: .utility).async {
            Defaults.performBatch(persist)
        }
        #else
        persist()
        endSheet()
        #endif
    }

    @objc private func cancelClicked(_ sender: NSButton) {
        endSheet()
    }

    private func endSheet() {
        if let onDismiss {
            onDismiss()
            owner?.configureSheetDidClose()
            return
        }
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window?.close()
        }
        owner?.configureSheetDidClose()
    }

    func windowWillClose(_ notification: Notification) {
        owner?.configureSheetDidClose()
    }
}
