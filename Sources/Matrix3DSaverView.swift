import Cocoa
import MetalKit
import ScreenSaver

/// Entry point of the bundle (`NSPrincipalClass` in Info.plist).
///
/// `@objc(Matrix3DSaverView)` gives the class a stable Objective-C name
/// unaffected by Swift's name mangling, so Info.plist can find it under
/// exactly this string.
///
/// Under `APPEX` (screensaver extension), the exit/duplicate workarounds
/// for `legacyScreenSaver` don't apply; lifecycle comes from the
/// extension's own process.
@objc(Matrix3DSaverView)
final class Matrix3DSaverView: ScreenSaverView {
    private var mtkView: MTKView!
    private var renderer: Renderer?
    private var sheetController: ConfigureSheetController?
    private(set) var screenID: Int32?
    #if APPEX
    /// Hosts the MTKView off the remoted view tree. CAMetalLayer inside the
    /// ViewBridge hierarchy makes the whole remote surface black.
    private var metalHostWindow: NSWindow?
    /// Latest Metal frame for AppKit remoting.
    private var bridgeImage: CGImage?
    private let bridgeImageLock = NSLock()
    private var appexShutdown = false
    #endif
    /// Guards against overlapping async GPU-upgrade attempts (viewDidMoveToWindow
    /// and startAnimation can both trigger one back-to-back). Shared with the
    /// legacy `.saver` target too -- dual-GPU Macs need the same "wait for
    /// the discrete card to wake up, without blocking the main thread"
    /// handling on both.
    private var gpuUpgradeInFlight = false
    /// True after a discrete-GPU switch succeeded but the Renderer rebuild on
    /// that device failed -- without this, `ensureDiscreteMetalDeviceIfNeeded`
    /// would see `current.isLowPower == false` and never retry, leaving the
    /// screen black for the rest of the session.
    private var lastGPUSwitchRendererFailed = false

    /// True as soon as a NEWER instance has taken over the same screen (see
    /// retireSilently()) -- animateOneFrame then stops drawing.
    private var isRetired = false
    private var countedAsLive = false
    private var lastHeartbeatWrite: CFAbsoluteTime = 0
    private var configOpen = false
    /// Time this instance was created (anti-leak: a stale willstop from a
    /// previous session shouldn't immediately terminate fresh instances).
    private var createdAt: CFAbsoluteTime = 0
    /// Host animateOneFrame counter; the watchdog only kicks in if no ticks
    /// arrive after start.
    private var frameNo = 0
    /// True once the internal MTK display link has taken over the clock,
    /// because the host isn't delivering animateOneFrame calls.
    private var watchdogInternal = false

    // MARK: - Sheet pause across all instances in the process

    private static weak var sheetOwnerInstance: Matrix3DSaverView?

    private static func sheetIsOpen() -> Bool {
        // Only trust the explicit open/close path (configureSheet /
        // configureSheetDidClose). Auto-clearing when `sheetParent == nil`
        // or from startAnimation was meant to fix "cannot begin sheet a
        // second time", but under Sequoia Settings it falsely dropped the
        // open flag ~1s after Options appeared and the panel closed itself.
        guard let owner = sheetOwnerInstance else { return false }
        return owner.configOpen
    }

    private static let thumbnailPlaceholderSize = NSSize(width: 160, height: 100)

    #if !APPEX
    // MARK: - Process-wide instance management (legacyScreenSaver / .saver only)

    private static var liveInstanceCount = 0
    private static var realInstanceByScreen: [Int32?: Matrix3DSaverView] = [:]
    private(set) static var lastKnownRealScreenID: Int32?

    private static func registerRealInstance(_ instance: Matrix3DSaverView, screenID: Int32?) {
        lastKnownRealScreenID = screenID
        if let screenID {
            Defaults.writeLastActiveScreenID(screenID)
        }
        let single = ScreenRegistry.isSingleDisplay()
        let log = MeshAtlas.makeLogger(tag: "instance")
        for (sid, inst) in realInstanceByScreen {
            if inst === instance {
                if sid != screenID { realInstanceByScreen.removeValue(forKey: sid) }
                continue
            }
            if sid == screenID || single {
                if inst.window != nil {
                    log("Screen \(sid.map(String.init) ?? "nil"): older instance is attached to a window (visible) -- NOT retired, new instance \(screenID.map(String.init) ?? "nil") runs in parallel")
                    continue
                }
                log("Screen \(sid.map(String.init) ?? "nil"): older windowless instance is being retired by the new one (screen \(screenID.map(String.init) ?? "nil"), single=\(single))")
                inst.retireSilently()
                realInstanceByScreen.removeValue(forKey: sid)
            }
        }
        realInstanceByScreen[screenID] = instance
    }

    private static func unregisterRealInstance(_ instance: Matrix3DSaverView, screenID: Int32?) {
        if realInstanceByScreen[screenID] === instance {
            realInstanceByScreen.removeValue(forKey: screenID)
        }
    }

    private func retireSilently() {
        isRetired = true
        Self.deregisterInstance(self)
    }

    private static func deregisterInstance(_ instance: Matrix3DSaverView) {
        if instance.countedAsLive {
            liveInstanceCount -= 1
            instance.countedAsLive = false
        }
    }
    #else
    /// Appex: track instances for sheet-pause only (no retire/exit).
    ///
    /// Deliberately does not actively pause older same-screen instances to
    /// cap concurrent Metal-active instances at one per screen: under
    /// WallpaperAgent there's no reliable way to tell from in here whether
    /// the host still considers a given instance live, and pausing one it
    /// does stop it from publishing frames -- which makes the host treat it
    /// as unresponsive and kill/relaunch it, producing new stalls
    /// (`loadView()` succeeding but never reaching
    /// `viewDidMoveToWindow`/`startAnimation`, multi-minute silent gaps)
    /// instead of fixing the original pileup. Pure tracking plus the
    /// per-instance cost reduction (lower preferredFramesPerSecond, see
    /// `enableInternalDisplayLink`) is the safer lever.
    private(set) static var lastKnownRealScreenID: Int32?
    private static var realInstanceByScreen: [Int32?: Matrix3DSaverView] = [:]

    private static func registerRealInstance(_ instance: Matrix3DSaverView, screenID: Int32?) {
        lastKnownRealScreenID = screenID
        if let screenID {
            Defaults.writeLastActiveScreenID(screenID)
        }
        realInstanceByScreen[screenID] = instance
    }

    private static func unregisterRealInstance(_ instance: Matrix3DSaverView, screenID: Int32?) {
        if realInstanceByScreen[screenID] === instance {
            realInstanceByScreen.removeValue(forKey: screenID)
        }
    }
    #endif

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit(isPreview: isPreview)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit(isPreview: false)
    }

    private func commonInit(isPreview: Bool) {
        #if APPEX
        Defaults.migrateFromLegacyIfNeeded()
        #endif
        let log = MeshAtlas.makeLogger(tag: "view")
        log("commonInit start: isPreview=\(isPreview) frame=\(frame.size)")

        createdAt = CFAbsoluteTimeGetCurrent()

        animationTimeInterval = isPreview ? 1.0 / 20.0 : 1.0 / 30.0

        #if !APPEX
        Self.liveInstanceCount += 1
        countedAsLive = true
        #endif

        self.screenID = isPreview ? nil : (ScreenRegistry.screenID(forFrameSize: frame.size) ?? ScreenRegistry.screenID(for: self))
        if !isPreview {
            Self.registerRealInstance(self, screenID: screenID)
        }

        var mtkFrame = bounds
        if isPreview && (mtkFrame.width < 10 || mtkFrame.height < 10) {
            mtkFrame = NSRect(origin: .zero, size: Self.thumbnailPlaceholderSize)
        }
        if mtkFrame.width < 10 || mtkFrame.height < 10 {
            mtkFrame = NSRect(origin: .zero, size: NSSize(width: 800, height: 500))
        }

        let view = MTKView(frame: mtkFrame)
        view.autoresizingMask = [.width, .height]
        // Dual-GPU: prefer discrete (AMD) if it's already awake, but never
        // block commonInit waiting for a GPU switch -- under APPEX this runs
        // on the ViewBridge-hosted main thread, and a multi-second stall here
        // reads to the host as an unresponsive extension. The async upgrade
        // below (ensureDiscreteMetalDeviceIfNeeded) catches up shortly after.
        //
        // A bounded synchronous wait here (for the legacy full-screen case)
        // isn't needed: the discrete GPU is already selected on the first
        // attempt, so a black screen in that case has a different cause --
        // see the drawable-size cap below.
        view.device = MetalDevicePicker.preferredReady(timeoutSeconds: 0, log: { log($0) })
        if view.device == nil {
            log("commonInit: no MTLDevice on the immediate attempt")
        }
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        // 4x MSAA: both targets now render at a capped, downscaled resolution
        // (see the drawable-size cap below / metalDownscaleFactor for appex)
        // and then get upscaled on screen, which makes aliasing on diagonal
        // edges (rain glyphs, the 3D object) much more visible than it was at
        // native resolution. MSAA smooths those edges cheaply -- the render
        // target is small now, so 4x sampling is affordable.
        view.sampleCount = 4
        view.enableSetNeedsDisplay = false
        view.isPaused = true // ScreenSaverView drives the clock via animateOneFrame.
        #if APPEX
        view.framebufferOnly = false
        wantsLayer = true
        // Prefer layer.contents updates (no AppKit redraw storm).
        layerContentsRedrawPolicy = .never
        let renderSize = Self.metalRenderSize(for: mtkFrame.size, preview: isPreview)
        if let layer {
            layer.isOpaque = true
            layer.backgroundColor = NSColor.black.cgColor
            // The published CGImage is rendered at a capped, downscaled
            // resolution (see metalDownscaleFactor) and stretched up to fill
            // this layer -- CALayer's default (linear) magnification blurs
            // that stretch noticeably, on top of already being downscaled.
            // Nearest keeps glyph/edge detail crisp (blockier rather than
            // soft), but at a large enough stretch factor (a bigger/higher-
            // resolution secondary monitor needs a much stronger downscale
            // than the built-in display) nearest turns the soft MSAA-
            // smoothed edges of the 3D object into visible chunky steps --
            // worse than the slight blur linear would add. Past a moderate
            // stretch, prefer linear to keep those edges smooth again.
            let backingScale = CGFloat(ScreenRegistry.backingScale(for: self))
            let physicalWidth = mtkFrame.width * backingScale
            let upscaleRatio = renderSize.width > 0 ? physicalWidth / renderSize.width : 1.0
            layer.magnificationFilter = upscaleRatio > 2.0 ? .linear : .nearest
        }
        let host = NSWindow(
            contentRect: NSRect(origin: .zero, size: renderSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.backingType = .buffered
        host.isOpaque = true
        host.backgroundColor = .black
        let hostRoot = NSView(frame: NSRect(origin: .zero, size: renderSize))
        hostRoot.wantsLayer = true
        host.contentView = hostRoot
        view.frame = hostRoot.bounds
        hostRoot.addSubview(view)
        host.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        host.orderBack(nil)
        metalHostWindow = host
        self.mtkView = view
        log("commonInit APPEX: offscreen MTK \(Int(renderSize.width))x\(Int(renderSize.height)) (view \(Int(mtkFrame.width))x\(Int(mtkFrame.height)))")
        #else
        addSubview(view)
        self.mtkView = view
        var legacyGlyphDownscale: Float = 1.0
        // Same reasoning as the appex layer.magnificationFilter above: the
        // drawable is capped/downscaled for the real full-screen case (see
        // the cap block right below) and CAMetalLayer's default (linear)
        // magnification blurs that upscale noticeably. Nearest keeps glyph/
        // edge detail crisp -- but past a moderate stretch factor (a bigger/
        // higher-resolution secondary monitor needs a much stronger
        // downscale than the built-in display) it turns the soft MSAA-
        // smoothed edges of the 3D object into visible chunky steps instead,
        // worse than linear's slight blur. Default to nearest; the cap block
        // below switches to linear once the actual stretch factor is known.
        view.layer?.magnificationFilter = .nearest
        if !isPreview {
            // Cap the actual Metal render resolution well below native (a
            // 4K-class panel can be 4096x2560) while keeping the on-screen
            // FRAME at full size -- CAMetalLayer scales the smaller drawable
            // up automatically, like a lower-res video on a big screen.
            // legacyScreenSaver.appex hosts this view via ViewBridge, and
            // large CAMetalLayer surfaces fail to composite there regardless
            // of GPU readiness or wait time -- only a small drawable (like
            // the 320x200 preview) actually renders. Capping the drawable
            // resolution avoids that limit entirely, and is far cheaper than
            // the offscreen-Metal+CGImage bridge the appex target needs for
            // its own (different) ViewBridge/CAMetalLayer problem.
            let realBackingScale = CGFloat(ScreenRegistry.backingScale(for: self))
            let fullPixelW = mtkFrame.width * realBackingScale
            let fullPixelH = mtkFrame.height * realBackingScale
            let maxEdge: CGFloat = 1280
            let longEdge = max(fullPixelW, fullPixelH)
            if longEdge > maxEdge {
                let scale = maxEdge / longEdge
                view.autoResizeDrawable = false
                view.drawableSize = NSSize(
                    width: max(2, floor(fullPixelW * scale)),
                    height: max(2, floor(fullPixelH * scale))
                )
                legacyGlyphDownscale = Float(scale)
                if 1.0 / scale > 2.0 {
                    view.layer?.magnificationFilter = .linear
                }
                log("commonInit: drawable size capped to \(view.drawableSize) (native would be \(Int(fullPixelW))x\(Int(fullPixelH)))")
            }
        }
        #endif

        #if APPEX
        let glyphDownscale = Self.metalDownscaleFactor(for: mtkFrame.size, preview: isPreview)
        #else
        // Matches the drawable-size cap above (1.0 when not capped, e.g.
        // preview or a screen small enough not to need it) -- without this,
        // glyphs would be sized for the native resolution but rendered into
        // the smaller, upscaled drawable, making them look too large (same
        // class of bug fixed for the appex target's own downscale earlier).
        let glyphDownscale = legacyGlyphDownscale
        #endif
        if let renderer = Renderer(mtkView: view, isPreview: isPreview, screenID: screenID, glyphDownscaleFactor: glyphDownscale) {
            self.renderer = renderer
            view.delegate = renderer
            #if APPEX
            renderer.bridgeLayer = self.layer
            renderer.onBridgeFrame = { [weak self] image in
                self?.acceptBridgeFrame(image)
            }
            #endif
            log("commonInit: Renderer created successfully, delegate set")
        } else {
            NSLog("[Matrix3DSaverX] Renderer initialization failed")
            log("commonInit: Renderer(...) returned nil -- the view will NEVER draw this session (no retry). See the [renderer] log lines right before this for details.")
        }

        #if !APPEX
        registerExitOnStop()
        #endif
    }

    #if APPEX
    /// Factor by which `metalRenderSize` has shrunk the Metal target
    /// relative to `viewSize` (1.0 = no shrink). Screens below the
    /// `maxEdge` cap get 1.0, larger screens a factor < 1 -- the higher the
    /// native resolution, the smaller. Without correction, glyphs (font
    /// size only depends on `backingScale`, not on this downscale) would
    /// get bigger after upscaling to the real screen the stronger the
    /// downscale was -- i.e. different screens would have DIFFERENT
    /// optical glyph sizes instead of a consistent look everywhere. This
    /// factor corrects for that.
    private static func metalDownscaleFactor(for viewSize: NSSize, preview: Bool) -> Float {
        let maxEdge: CGFloat = preview ? 960 : 1280
        let longEdge = max(max(viewSize.width, 2), max(viewSize.height, 2))
        guard longEdge > maxEdge else { return 1.0 }
        return Float(maxEdge / longEdge)
    }

    /// Cap Metal/CI resolution — full Retina screens make CGImage publish too slow (stutter).
    private static func metalRenderSize(for viewSize: NSSize, preview: Bool) -> NSSize {
        let w = max(viewSize.width, 2)
        let h = max(viewSize.height, 2)
        let scale = CGFloat(metalDownscaleFactor(for: viewSize, preview: preview))
        return NSSize(width: max(2, floor(w * scale)), height: max(2, floor(h * scale)))
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    private func acceptBridgeFrame(_ image: CGImage) {
        guard !appexShutdown else { return }
        bridgeImageLock.lock()
        bridgeImage = image
        bridgeImageLock.unlock()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        layer?.contentsGravity = .resize
        CATransaction.commit()
    }

    private func recreateMetalHostIfNeeded() {
        guard metalHostWindow == nil, let view = mtkView else { return }
        let renderSize = Self.metalRenderSize(for: bounds.size, preview: isPreview)
        let host = NSWindow(
            contentRect: NSRect(origin: .zero, size: renderSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.isOpaque = true
        host.backgroundColor = .black
        let hostRoot = NSView(frame: NSRect(origin: .zero, size: renderSize))
        hostRoot.wantsLayer = true
        host.contentView = hostRoot
        view.removeFromSuperview()
        view.frame = hostRoot.bounds
        hostRoot.addSubview(view)
        host.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        host.orderBack(nil)
        metalHostWindow = host
        MeshAtlas.makeLogger(tag: "view")("recreateMetalHostIfNeeded \(Int(renderSize.width))x\(Int(renderSize.height))")
    }

    /// Pause drawing without destroying the offscreen Metal host (restartable).
    func pauseAppexMetal() {
        watchdogInternal = false
        mtkView?.isPaused = true
        mtkView?.delegate = nil
        renderer?.onBridgeFrame = nil
        MeshAtlas.makeLogger(tag: "view")("pauseAppexMetal()")
    }

    /// Tear down Metal host + callbacks so the extension can idle.
    /// Drops the discrete MTLDevice so Automatic switching can return to Intel.
    /// Do NOT exit(0) here — that breaks System Settings Options / selection.
    func shutdownAppexResources() {
        pauseAppexMetal()
        guard !appexShutdown else {
            releaseDiscreteGPUHold(logTag: "shutdown-idempotent")
            return
        }
        appexShutdown = true
        renderer?.bridgeLayer = nil
        if let host = metalHostWindow {
            host.orderOut(nil)
            host.contentView = nil
            host.close()
        }
        metalHostWindow = nil
        bridgeImageLock.lock()
        bridgeImage = nil
        bridgeImageLock.unlock()
        layer?.contents = nil
        releaseDiscreteGPUHold(logTag: "shutdown")
        MeshAtlas.makeLogger(tag: "view")("shutdownAppexResources()")
    }

    /// Drop Renderer + MTLDevice so macOS can power down the discrete GPU.
    private func releaseDiscreteGPUHold(logTag: String) {
        let log = MeshAtlas.makeLogger(tag: "view")
        let wasLowPower = mtkView?.device?.isLowPower
        let name = mtkView?.device?.name
        mtkView?.delegate = nil
        renderer = nil
        mtkView?.device = nil
        log(
            "releaseDiscreteGPUHold(\(logTag)): dropped device=\(name ?? "nil") " +
            "wasLowPower=\(wasLowPower.map(String.init) ?? "n/a")"
        )
    }
    #endif

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        #if APPEX
        AppexLog.logger("View").info(
            "viewDidMoveToWindow() hasWindow=\(self.window != nil) isPreview=\(self.isPreview) bounds=\(self.bounds.size.width, privacy: .public)x\(self.bounds.size.height, privacy: .public)"
        )
        if window == nil {
            shutdownAppexResources()
            return
        }
        // ViewBridge often never delivers animateOneFrame — drive MTK ourselves.
        appexShutdown = false
        ensureDiscreteMetalDeviceIfNeeded()
        recreateMetalHostIfNeeded()
        ensureMtkLayout()
        renderer?.bridgeLayer = layer
        enableInternalDisplayLink()
        return
        #else
        guard !isPreview else { return }
        if window == nil {
            if watchdogInternal {
                watchdogInternal = false
                mtkView?.isPaused = true
            }
            return
        }
        if isRetired {
            MeshAtlas.makeLogger(tag: "instance")("viewDidMoveToWindow: a retired instance got a window -> reactivated")
            isRetired = false
            if !countedAsLive {
                Self.liveInstanceCount += 1
                countedAsLive = true
            }
        }
        // Dual-GPU: if commonInit's quick device pick landed on the
        // integrated GPU (or none), catch up to the discrete one now,
        // asynchronously.
        ensureDiscreteMetalDeviceIfNeeded()
        ensureMtkLayout()
        if let newID = ScreenRegistry.screenID(for: self), newID != screenID {
            MeshAtlas.makeLogger(tag: "instance")(
                "viewDidMoveToWindow: screenID \(screenID.map(String.init) ?? "nil") -> \(newID) (frame=\(frame.size), window.screen=\(window?.screen?.localizedName ?? "nil")) -- adopted LOCALLY only, no retiring of other instances"
            )
            screenID = newID
            renderer?.screenID = newID
        }
        #endif
    }

    override func startAnimation() {
        super.startAnimation()
        #if APPEX
        AppexLog.logger("View").info("startAnimation() isPreview=\(self.isPreview)")
        appexShutdown = false
        // If commonInit raced the GPU switch, retry discrete device now.
        ensureDiscreteMetalDeviceIfNeeded()
        recreateMetalHostIfNeeded()
        ensureMtkLayout()
        if let renderer {
            mtkView.delegate = renderer
            renderer.bridgeLayer = layer
            renderer.onBridgeFrame = { [weak self] image in
                self?.acceptBridgeFrame(image)
            }
        }
        enableInternalDisplayLink()
        return
        #else
        frameNo = 0
        watchdogInternal = false
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(watchdogCheckTicks), object: nil
        )
        perform(#selector(watchdogCheckTicks), with: nil, afterDelay: 2.0)
        // Do NOT clear configOpen / sheetOwner here — Settings often
        // restarts preview animation while Options is still open.
        // If commonInit raced the GPU switch, retry discrete device now.
        ensureDiscreteMetalDeviceIfNeeded()
        ensureMtkLayout()
        #endif
    }

    #if APPEX
    /// Own display link — Appex/ViewBridge does not reliably call animateOneFrame.
    private func enableInternalDisplayLink() {
        guard !appexShutdown, !isRetired, mtkView != nil else { return }
        watchdogInternal = true
        mtkView.isPaused = false
        // Kept deliberately conservative rather than the smoother rate the
        // hardware could sustain: WallpaperAgent can keep several instances
        // alive and fully rendering at once (thumbnail + live preview + old/
        // new model after a switch), and pushing the frame rate up overloads
        // the host into killing processes mid-reinit. Heavy custom USDZ
        // models make this worse, since each newly spawned process has to
        // (re-)parse the mesh itself (no cross-process cache) on top of the
        // per-frame cost. If instability returns, lower this rate again
        // before touching instance management (see the tracking-only
        // comment above); the built-in (fast-loading) models alone can
        // likely tolerate a higher rate than heavy custom ones.
        mtkView.preferredFramesPerSecond = isPreview ? 5 : 10
        NSLog(
            "[Matrix3DSaverX] enableInternalDisplayLink preview=%d fps=%d size=%.0fx%.0f renderer=%@",
            isPreview,
            isPreview ? 5 : 10,
            bounds.width,
            bounds.height,
            renderer != nil ? "ok" : "nil"
        )
        MeshAtlas.makeLogger(tag: "view")(
            "enableInternalDisplayLink preview=\(isPreview) size=\(bounds.size) drawable=\(mtkView.drawableSize) fbOnly=\(mtkView.framebufferOnly)"
        )
    }
    #endif

    /// If Automatic switching left us on Intel (or without a device), asynchronously
    /// wait for / force discrete AMD and rebuild the Renderer (Metal objects are
    /// per-device). Never blocks the main thread -- ViewBridge hosts a stalled
    /// main run loop as an unresponsive extension, so a blocking `Thread.sleep`
    /// here would risk the same instability under APPEX. Shared with the
    /// legacy `.saver` target too: `commonInit`'s
    /// `MetalDevicePicker.preferredReady(timeoutSeconds:)` call only gets one
    /// quick, non-blocking attempt (see its own comment), and this is what
    /// catches up asynchronously afterwards on both targets.
    private func ensureDiscreteMetalDeviceIfNeeded() {
        guard let mtkView else { return }
        guard !gpuUpgradeInFlight else { return }
        let log = MeshAtlas.makeLogger(tag: "view")
        let hasDiscrete = MTLCopyAllDevices().contains { !$0.isLowPower }
        let current = mtkView.device
        let needsSwitch = current == nil
            || (hasDiscrete && current?.isLowPower == true)
            || lastGPUSwitchRendererFailed
            // commonInit's Renderer(...) build can fail for reasons that have
            // nothing to do with which device is picked (e.g. transient Metal
            // resource contention from a still-exiting previous instance during
            // a fast re-trigger) -- without this, a device that already looks
            // fine (non-nil, not low-power) never gets a retry, and the view
            // stays black for the rest of the session with no way to recover.
            || renderer == nil
        guard needsSwitch else { return }

        gpuUpgradeInFlight = true
        let wait: TimeInterval = isPreview ? 0.5 : 2.0
        log(
            "ensureDiscreteMetalDevice: current=\(current?.name ?? "nil") " +
            "lowPower=\(current?.isLowPower ?? true) — async wait \(wait)s for discrete"
        )
        MetalDevicePicker.preferredReadyAsync(timeoutSeconds: wait, log: { log($0) }) { [weak self] device in
            guard let self else { return }
            self.gpuUpgradeInFlight = false
            #if APPEX
            guard !self.appexShutdown, let mtkView = self.mtkView else { return }
            #else
            guard !self.isRetired, let mtkView = self.mtkView else { return }
            #endif
            guard let device else {
                log("ensureDiscreteMetalDevice: still no MTLDevice")
                return
            }
            if mtkView.device?.registryID == device.registryID, self.renderer != nil, !self.lastGPUSwitchRendererFailed {
                return
            }

            self.lastGPUSwitchRendererFailed = false
            mtkView.device = device
            mtkView.delegate = nil
            self.renderer = nil
            #if APPEX
            let glyphDownscale = Self.metalDownscaleFactor(for: self.bounds.size, preview: self.isPreview)
            #else
            let glyphDownscale: Float = 1.0
            #endif
            if let newRenderer = Renderer(mtkView: mtkView, isPreview: self.isPreview, screenID: self.screenID, glyphDownscaleFactor: glyphDownscale) {
                self.renderer = newRenderer
                #if APPEX
                newRenderer.bridgeLayer = self.layer
                newRenderer.onBridgeFrame = { [weak self] image in
                    self?.acceptBridgeFrame(image)
                }
                #endif
                mtkView.delegate = newRenderer
                log("ensureDiscreteMetalDevice: Renderer rebuilt on \(device.name)")
            } else {
                self.lastGPUSwitchRendererFailed = true
                log("ensureDiscreteMetalDevice: Renderer rebuild failed on \(device.name) -- will retry on the next call")
            }
        }
    }

    @objc private func watchdogCheckTicks() {
        guard frameNo == 0 else { return }
        guard !watchdogInternal, !isRetired else { return }
        guard !Self.sheetIsOpen() else { return }
        guard isAnimating else { return }
        MeshAtlas.makeLogger(tag: "view")(
            "watchdog: no animateOneFrame ticks after start -> internal MTK display link"
        )
        watchdogInternal = true
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = isPreview ? 20 : 30
    }

    #if APPEX
    override func draw(_ dirtyRect: NSRect) {
        // Remoting uses layer.contents; keep a black fill if empty.
        if layer?.contents == nil {
            NSColor.black.setFill()
            dirtyRect.fill()
        }
    }
    #endif

    private func ensureMtkLayout() {
        guard mtkView != nil else { return }
        let size = bounds.size
        let viewSize: NSSize
        if size.width >= 10, size.height >= 10 {
            viewSize = size
        } else if isPreview {
            viewSize = Self.thumbnailPlaceholderSize
        } else {
            return
        }
        #if APPEX
        let target = Self.metalRenderSize(for: viewSize, preview: isPreview)
        if let host = metalHostWindow {
            host.setContentSize(target)
            mtkView.frame = NSRect(origin: .zero, size: target)
        }
        #else
        mtkView.frame = NSRect(origin: .zero, size: viewSize)
        #endif
    }

    #if APPEX
    override func layout() {
        super.layout()
        ensureMtkLayout()
    }
    #endif

    override func animateOneFrame() {
        writeHeartbeat()
        guard !isRetired else { return }
        guard !Self.sheetIsOpen() else { return }
        frameNo += 1
        if watchdogInternal { return }
        mtkView.draw()
    }

    private func writeHeartbeat() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastHeartbeatWrite >= 5.0 else { return }
        lastHeartbeatWrite = now
        DispatchQueue.global(qos: .utility).async {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/legacyss-cleanup/heartbeat")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier))
            try? String(CFAbsoluteTimeGetCurrent()).write(to: path, atomically: true, encoding: .utf8)
        }
    }

    #if !APPEX
    // MARK: - Anti-leak exit (legacyScreenSaver / .saver only)

    private func registerExitOnStop() {
        guard !isPreview else { return }
        let nc = DistributedNotificationCenter.default()
        nc.addObserver(self, selector: #selector(screenSaverStopped(_:)),
                       name: Notification.Name("com.apple.screensaver.willstop"), object: nil)
        nc.addObserver(self, selector: #selector(screenSaverStopped(_:)),
                       name: Notification.Name("com.apple.screensaver.didstop"), object: nil)
        MeshAtlas.makeLogger(tag: "exit-on-stop")(
            "exit-on-stop active (anti-leak workaround registered)"
        )
    }

    @objc private func screenSaverStopped(_ note: Notification) {
        // Options sheet lives in this same legacyScreenSaver process. Exiting
        // while it is open kills the panel after ~2s (Sequoia Settings).
        guard !Self.sheetIsOpen() else {
            MeshAtlas.makeLogger(tag: "exit-on-stop")(
                "screenSaverStopped (\(note.name.rawValue)) ignored — Options sheet open"
            )
            return
        }
        let name = note.name.rawValue
        MeshAtlas.makeLogger(tag: "exit-on-stop")(
            "screenSaverStopped (\(name)) -> checking again in 2s [anti-leak]"
        )
        perform(#selector(exitIfReallyStopped), with: nil, afterDelay: 2.0)
    }

    @objc private func exitIfReallyStopped() {
        guard !Self.sheetIsOpen() else {
            MeshAtlas.makeLogger(tag: "exit-on-stop")(
                "exitIfReallyStopped: skipped — Options sheet open"
            )
            return
        }
        let age = CFAbsoluteTimeGetCurrent() - createdAt
        let log = MeshAtlas.makeLogger(tag: "exit-on-stop")
        if age <= 3.0 {
            log(
                "exitIfReallyStopped: instance is only \(String(format: "%.1f", age))s old "
                    + "(stale notification?) -> no exit"
            )
            return
        }
        log(
            "exitIfReallyStopped: stopped -> exit(0) [anti-leak] "
                + "(liveInstanceCount=\(Self.liveInstanceCount))"
        )
        exit(0)
    }

    @objc private func exitIfAllInstancesReallyStopped() {
        guard !Self.sheetIsOpen() else {
            MeshAtlas.makeLogger(tag: "exit-on-stop")(
                "exitIfAllInstancesReallyStopped: skipped — Options sheet open"
            )
            return
        }
        // Preview stops whenever Settings opens Options / refreshes the
        // thumbnail. Never exit(0) for previews — that closed the Options
        // panel after ~2s under Sequoia.
        guard !isPreview else {
            MeshAtlas.makeLogger(tag: "exit-on-stop")(
                "exitIfAllInstancesReallyStopped: skipped — preview instance"
            )
            return
        }
        let age = CFAbsoluteTimeGetCurrent() - createdAt
        let log = MeshAtlas.makeLogger(tag: "exit-on-stop")
        if age <= 3.0 {
            log(
                "exitIfAllInstancesReallyStopped: instance is only "
                    + "\(String(format: "%.1f", age))s old -> no exit"
            )
            return
        }
        Self.deregisterInstance(self)
        log(
            "exitIfAllInstancesReallyStopped: stopped -> exit(0) [anti-leak] "
                + "(liveInstanceCount=\(Self.liveInstanceCount))"
        )
        exit(0)
    }

    /// Cancel pending anti-leak exits for every live instance (Options open).
    private static func cancelPendingAntiLeakExits() {
        for (_, inst) in realInstanceByScreen {
            NSObject.cancelPreviousPerformRequests(
                withTarget: inst, selector: #selector(exitIfReallyStopped), object: nil
            )
            NSObject.cancelPreviousPerformRequests(
                withTarget: inst, selector: #selector(exitIfAllInstancesReallyStopped), object: nil
            )
        }
    }
    #endif

    override func stopAnimation() {
        #if APPEX
        AppexLog.logger("View").info("stopAnimation() isPreview=\(self.isPreview)")
        #endif
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(watchdogCheckTicks), object: nil
        )
        if watchdogInternal {
            watchdogInternal = false
            mtkView?.isPaused = true
        }
        // Keep sheetOwner while Options may still be open (stopAnimation
        // fires when Settings pauses the preview for the Options panel).
        if !isPreview {
            Self.unregisterRealInstance(self, screenID: screenID)
        }
        #if APPEX
        // Never exit(0) and never full-teardown on stop — Settings Options /
        // selection break if the extension process or Metal host dies here.
        // GPU hold is released in shutdownAppexResources when the view leaves
        // its window (viewDidMoveToWindow nil).
        pauseAppexMetal()
        #endif
        #if !APPEX
        // Anti-leak exit is ONLY for real full-screen instances. Scheduling it
        // from preview stopAnimation closed Options after ~2s on Sequoia
        // (Settings stops the preview when the sheet appears).
        if !isPreview, !Self.sheetIsOpen() {
            MeshAtlas.makeLogger(tag: "exit-on-stop")(
                "stopAnimation preview=\(isPreview) -> exitIfAll in 2s "
                    + "(liveInstanceCount=\(Self.liveInstanceCount))"
            )
            perform(#selector(exitIfAllInstancesReallyStopped), with: nil, afterDelay: 2.0)
        } else {
            MeshAtlas.makeLogger(tag: "exit-on-stop")(
                "stopAnimation preview=\(isPreview) sheetOpen=\(Self.sheetIsOpen()) "
                    + "-> no anti-leak exit"
            )
        }
        #endif
        super.stopAnimation()
    }

    #if !APPEX
    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        // Confirms the host actually asked for a sheet -- when "Options"
        // silently does nothing, this line is absent entirely, proving the
        // host never called this getter (a documented Apple-side bug in the
        // legacyScreenSaver.appex hosting layer, not something fixable
        // here; see the "Known limitation" section in README.md).
        MeshAtlas.makeLogger(tag: "view")("configureSheet requested: isPreview=\(isPreview)")
        // Cancel any already-queued exit(0) from a prior stopAnimation —
        // Settings often stops the preview before/while asking for the sheet.
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(exitIfAllInstancesReallyStopped), object: nil
        )
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(exitIfReallyStopped), object: nil
        )
        Self.cancelPendingAntiLeakExits()
        let controller = ConfigureSheetController(owner: self)
        sheetController = controller
        configOpen = true
        Self.sheetOwnerInstance = self
        Self.pauseAllWatchdogDrivenViews()
        return controller.window
    }
    #endif

    func configureSheetDidClose() {
        configOpen = false
        if Self.sheetOwnerInstance === self {
            Self.sheetOwnerInstance = nil
        }
        sheetController = nil
        ensureMtkLayout()
        Self.resumeAllWatchdogDrivenViews()
    }

    private static func pauseAllWatchdogDrivenViews() {
        for (_, inst) in realInstanceByScreen {
            if inst.watchdogInternal {
                inst.mtkView?.isPaused = true
            }
        }
    }

    private static func resumeAllWatchdogDrivenViews() {
        for (_, inst) in realInstanceByScreen {
            if inst.watchdogInternal, !inst.isRetired {
                inst.mtkView?.isPaused = false
            }
        }
    }

    #if DEBUG
    @objc(makeForTesting)
    static func makeForTesting() -> Matrix3DSaverView? {
        Matrix3DSaverView(frame: NSRect(x: 0, y: 0, width: 900, height: 560), isPreview: false)
    }

    @objc(makeForTestingTiny)
    static func makeForTestingTiny() -> Matrix3DSaverView? {
        Matrix3DSaverView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), isPreview: false)
    }
    #endif
}
