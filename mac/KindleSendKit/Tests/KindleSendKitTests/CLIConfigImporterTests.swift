import Foundation
import Testing
@testable import KindleSendKit

struct CLIConfigImporterTests {
    @Test func importsICloud() throws {
        let url = try #require(Bundle.module.url(forResource: "cli_config", withExtension: "toml", subdirectory: "Fixtures"))
        let imported = try #require(CLIConfigImporter.parse(toml: String(contentsOf: url, encoding: .utf8)))
        #expect(imported.settings.kindleEmail == "yourname_abc123@kindle.com")
        #expect(imported.settings.provider == .icloud)
        #expect(imported.settings.user == "you@icloud.com")
        #expect(imported.password == "abcd-efgh-ijkl-mnop")
    }

    @Test func sesDefaultReturnsNil() {
        #expect(CLIConfigImporter.parse(toml: "kindle_email = \"a@kindle.com\"\nprovider = \"ses\"\n[ses]\nfrom = \"x@y.com\"\n") == nil)
    }

    @Test func importsCustomSMTPWithPort() throws {
        let toml = "kindle_email = \"a@kindle.com\"\nprovider = \"smtp\"\n[smtp]\nhost = \"mail.example.com\"\nport = 587\nuser = \"you\"\npassword = \"p\\\"w\" # note\n"
        let imported = try #require(CLIConfigImporter.parse(toml: toml))
        #expect(imported.settings.provider == .custom)
        #expect(imported.settings.customHost == "mail.example.com")
        #expect(imported.settings.customPort == 587)
        #expect(imported.password == "p\"w")
    }

    @Test func migratesLegacyFlatConfig() throws {
        let toml = "kindle_email = \"a@kindle.com\"\nsmtp_user = \"me@gmail.com\"\nsmtp_password = \"pw\"\nsmtp_port = 587\n"
        let imported = try #require(CLIConfigImporter.parse(toml: toml))
        #expect(imported.settings.provider == .gmail)
        #expect(imported.settings.user == "me@gmail.com")
        #expect(imported.password == "pw")
    }
}
