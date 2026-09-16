import Foundation

private let logger = AppexLog.logger("PluginManager")

/// Installs/uninstalls the embedded screensaver extension and reports its
/// current registration state to the host app's UI.
///
/// There's no public Swift API to query or (un)register an App Extension by
/// bundle identifier, so this shells out to `/usr/bin/pluginkit`, the same
/// tool `pluginkit -m` uses to list registered extensions.
@MainActor
final class PluginManager: ObservableObject {
    @Published var isInstalled: Bool = false
    @Published var installedVersion: String?
    @Published var installedPath: String?
    @Published var isLoading: Bool = false
    @Published var lastError: String?

    private var bundleIdentifier: String {
        if let path = embeddedExtensionPath,
           let id = Bundle(path: path)?.bundleIdentifier {
            return id
        }
        if let appId = Bundle.main.bundleIdentifier {
            return appId.hasSuffix(".Extension") ? appId : "\(appId).Extension"
        }
        return "de.r8lle.screensaver.matrix3dx.app.Extension"
    }
    private let extensionFileName = "Matrix3DSaverXExtension.appex"

    var embeddedExtensionPath: String? {
        Bundle.main.builtInPlugInsURL?
            .appendingPathComponent(extensionFileName)
            .path
    }

    var embeddedVersion: String? {
        guard let path = embeddedExtensionPath,
              let bundle = Bundle(path: path),
              let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return version
    }

    init() {
        checkInstallationStatus()
    }

    /// Refreshes `isInstalled`/`installedPath`/`installedVersion` by asking
    /// `pluginkit` whether this extension's bundle identifier is currently
    /// registered.
    func checkInstallationStatus() {
        isLoading = true
        lastError = nil

        Task {
            do {
                let (isRegistered, path, version) = try await queryPluginKit()
                await MainActor.run {
                    self.isInstalled = isRegistered
                    self.installedPath = path
                    self.installedVersion = version
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.isInstalled = false
                    self.installedPath = nil
                    self.installedVersion = nil
                    self.isLoading = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    /// Lists registered screensaver-category extensions via `pluginkit -m -v`
    /// and picks out the line matching this extension's bundle identifier,
    /// parsing its version (in parentheses) and install path from the same
    /// line.
    private func queryPluginKit() async throws -> (Bool, String?, String?) {
        let output = try runProcess("/usr/bin/pluginkit", arguments: ["-m", "-v", "-p", "com.apple.screensaver"])

        for line in output.components(separatedBy: "\n") where line.contains(bundleIdentifier) {
            logger.info("Found extension in pluginkit: \(line, privacy: .public)")

            var version: String?
            if let versionStart = line.firstIndex(of: "("),
               let versionEnd = line.firstIndex(of: ")") {
                let start = line.index(after: versionStart)
                version = String(line[start..<versionEnd])
            }

            var path: String?
            if let pathStart = line.range(of: "/") {
                path = String(line[pathStart.lowerBound...]).trimmingCharacters(in: .whitespaces)
            }

            return (true, path, version)
        }

        return (false, nil, nil)
    }

    /// Registers the extension embedded in this app bundle with the system
    /// via `pluginkit -a`, so it appears in System Settings' screensaver list.
    func install() throws {
        guard let extensionPath = embeddedExtensionPath,
              FileManager.default.fileExists(atPath: extensionPath) else {
            throw PluginError.embeddedExtensionNotFound
        }

        logger.info("Installing extension from: \(extensionPath, privacy: .public)")
        isLoading = true
        lastError = nil

        do {
            _ = try runProcess("/usr/bin/pluginkit", arguments: ["-a", extensionPath])
            logger.info("Extension installed successfully")
            checkInstallationStatus()
        } catch {
            isLoading = false
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Unregisters the extension via `pluginkit -r`, preferring the actually
    /// installed path (which may differ from the embedded one after an
    /// app move/update) over the embedded path.
    func uninstall() throws {
        let extensionPath: String
        if let installed = installedPath, !installed.isEmpty {
            extensionPath = installed
        } else if let embedded = embeddedExtensionPath {
            extensionPath = embedded
        } else {
            throw PluginError.extensionPathNotFound
        }

        logger.info("Uninstalling extension at: \(extensionPath, privacy: .public)")
        isLoading = true
        lastError = nil

        do {
            _ = try runProcess("/usr/bin/pluginkit", arguments: ["-r", extensionPath])
            logger.info("Extension uninstalled successfully")
            checkInstallationStatus()
        } catch {
            isLoading = false
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Runs a command synchronously and returns its combined stdout+stderr.
    private func runProcess(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        logger.debug("Process output: \(output, privacy: .public)")

        if process.terminationStatus != 0 {
            logger.warning("Process exited with status: \(process.terminationStatus)")
        }

        return output
    }
}

enum PluginError: LocalizedError {
    case embeddedExtensionNotFound
    case extensionPathNotFound

    var errorDescription: String? {
        switch self {
        case .embeddedExtensionNotFound:
            return "Embedded extension not found in app bundle"
        case .extensionPathNotFound:
            return "Extension path not found"
        }
    }
}
