import AppKit
import ScreenSaver

private let logger = AppexLog.logger("ViewController")

/// Main view controller — sample-style loadView, plus start/stop forwarding so
/// the extension actually pauses Metal when the host tears down the session.
@objc(Matrix3DSaverXViewController)
class Matrix3DSaverXViewController: ScreenSaverViewController {

    private var saverView: Matrix3DSaverView?

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        logger.info("init(nibName:bundle:)")
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        logger.info("init(coder:)")
        super.init(coder: coder)
    }

    deinit {
        logger.info("deinit")
        saverView?.shutdownAppexResources()
    }

    /// Overrides plain `loadView()`, not the private `loadViewForFrame:
    /// isPreview:` hook declared in ScreenSaverPrivate.h. Under WallpaperAgent/
    /// ExtensionKit hosting that hook is never invoked -- using it instead
    /// silently breaks the whole lifecycle (loadView/commonInit never run;
    /// init/startAnimation/deinit loop continuously instead). The
    /// `NSScreen.main`-based isPreview guess below is an imperfect stand-in,
    /// but it's the one that actually works here.
    override func loadView() {
        logger.info("loadView()")

        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let isPreview = frame.width < 400

        let view = Matrix3DSaverView(frame: frame, isPreview: isPreview)
        saverView = view
        self.view = view ?? NSView(frame: frame)
        NSLog(
            "[Matrix3DSaverX] loadView isPreview=%d frame=%.0fx%.0f",
            isPreview, frame.width, frame.height
        )
    }

    @objc override func startAnimation() {
        logger.info("startAnimation()")
        super.startAnimation()
        saverView?.startAnimation()
    }

    @objc override func stopAnimation() {
        logger.info("stopAnimation()")
        saverView?.stopAnimation()
        super.stopAnimation()
    }
}
