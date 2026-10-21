import Foundation
import Testing
@testable import KindleSendKit

struct AppEnvironmentTests {
    private static let appSupport = URL(fileURLWithPath: "/Users/x/Library/Application Support", isDirectory: true)

    @Test func noOverridesUsesRealLocations() {
        let env = AppEnvironment(environment: [:], applicationSupport: Self.appSupport)
        #expect(env.dataDirectory.path == "/Users/x/Library/Application Support/KindleSend")
        #expect(env.defaultsSuite == nil)
        #expect(env.keychainService == "com.by32.KindleSend")
        #expect(env.cliConfigURL == CLIConfigImporter.defaultURL)
    }

    @Test func dataDirOverrideIsolatesEverything() {
        let env = AppEnvironment(environment: ["KINDLESEND_DATA_DIR": "/tmp/ks"], applicationSupport: Self.appSupport)
        #expect(env.dataDirectory.path == "/tmp/ks")
        #expect(env.defaultsSuite == "com.by32.KindleSend.test")
        #expect(env.keychainService == "com.by32.KindleSend.test")
        #expect(env.cliConfigURL.path == "/tmp/ks/cli-config.toml")
    }

    @Test func suiteOverrideIsHonoredOnlyWithDataDir() {
        let both = AppEnvironment(environment: ["KINDLESEND_DATA_DIR": "/tmp/ks", "KINDLESEND_DEFAULTS_SUITE": "custom.suite"],
                                  applicationSupport: Self.appSupport)
        #expect(both.defaultsSuite == "custom.suite")
        let suiteOnly = AppEnvironment(environment: ["KINDLESEND_DEFAULTS_SUITE": "custom.suite"], applicationSupport: Self.appSupport)
        #expect(suiteOnly.defaultsSuite == nil)
        #expect(suiteOnly.keychainService == "com.by32.KindleSend")
    }
}
