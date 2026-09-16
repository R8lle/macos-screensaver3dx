import Foundation
import os.log

/// Shared logging for host app and screensaver extension.
/// Console filter: subsystem == "de.r8lle.screensaver.matrix3dx"
enum AppexLog {
    static var subsystem: String {
        Bundle.main.bundleIdentifier ?? "de.r8lle.screensaver.matrix3dx"
    }

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
