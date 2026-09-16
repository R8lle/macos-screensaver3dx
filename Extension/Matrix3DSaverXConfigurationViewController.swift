import AppKit

private let logger = AppexLog.logger("Configuration")

/// Configuration sheet for System Settings Options.
///
/// Runtime base class is `NSServiceViewController` (ViewBridge). Closing the
/// panel requires `configureSheetDidEnd()` — `endSheet` / `dismiss(nil)` do
/// not dismiss a remote service view hosted by System Settings.
@objc(Matrix3DSaverXConfigurationViewController)
class Matrix3DSaverXConfigurationViewController: ScreenSaverConfigurationViewController {

    private var sheetController: ConfigureSheetController?

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
    }

    override func loadView() {
        logger.info("loadView()")
        Defaults.migrateFromLegacyIfNeeded()
        let controller = ConfigureSheetController(owner: nil, ownsWindow: false)
        controller.onDismiss = { [weak self] in
            self?.dismissSheet()
        }
        sheetController = controller
        self.view = controller.contentView
        preferredContentSize = controller.contentSize
    }

    private func dismissSheet() {
        NSLog("[Matrix3DSaverX] dismissSheet -> configureSheetDidEnd()")
        configureSheetDidEnd()
    }
}
