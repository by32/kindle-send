import Foundation

/// Where the app keeps its state. `KINDLESEND_DATA_DIR` switches every location to a test copy: that
/// directory for the data files, a separate defaults suite (`KINDLESEND_DEFAULTS_SUITE`, else
/// `com.by32.KindleSend.test`), a separate Keychain service, and a CLI config path inside the data
/// directory, so a test run never reads the real CLI config or touches the real Keychain item.
/// Without it, `KINDLESEND_DEFAULTS_SUITE` is ignored. The app passes an empty environment in Release.
public struct AppEnvironment: Sendable, Equatable {
    public static let testIdentifier = "com.by32.KindleSend.test"

    public var dataDirectory: URL
    /// nil = the standard defaults domain.
    public var defaultsSuite: String?
    public var keychainService: String
    public var cliConfigURL: URL

    public init(environment: [String: String],
                applicationSupport: URL = .applicationSupportDirectory) {
        if let dir = environment["KINDLESEND_DATA_DIR"], !dir.isEmpty {
            dataDirectory = URL(fileURLWithPath: dir, isDirectory: true)
            defaultsSuite = environment["KINDLESEND_DEFAULTS_SUITE"].flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.testIdentifier
            keychainService = Self.testIdentifier
            cliConfigURL = dataDirectory.appendingPathComponent("cli-config.toml")
        } else {
            dataDirectory = applicationSupport.appendingPathComponent("KindleSend", isDirectory: true)
            defaultsSuite = nil
            keychainService = "com.by32.KindleSend"
            cliConfigURL = CLIConfigImporter.defaultURL
        }
    }
}
