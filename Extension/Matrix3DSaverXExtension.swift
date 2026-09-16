import Foundation
import ScreenSaver

private let logger = AppexLog.logger("Extension")

/// Principal class for the screensaver extension (`NSExtensionPrincipalClass`).
@objc(Matrix3DSaverXExtension)
class Matrix3DSaverXExtension: ScreenSaverExtension {

    @objc override init() {
        logger.info("Matrix3DSaverXExtension.init() PID=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
        super.init()
    }

    deinit {
        logger.info("Matrix3DSaverXExtension.deinit")
    }
}
