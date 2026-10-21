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

    @Test func customSMTPWithoutPortDefaultsTo587() throws {
        let toml = "kindle_email = \"a@kindle.com\"\nprovider = \"smtp\"\n[smtp]\nhost = \"mail.example.com\"\nuser = \"you\"\n"
        let imported = try #require(CLIConfigImporter.parse(toml: toml))
        #expect(imported.settings.customPort == 587)
        #expect(imported.settings.account?.port == 587)
    }

    @Test func migratesLegacyFlatConfig() throws {
        let toml = "kindle_email = \"a@kindle.com\"\nsmtp_user = \"me@gmail.com\"\nsmtp_password = \"pw\"\nsmtp_port = 587\n"
        let imported = try #require(CLIConfigImporter.parse(toml: toml))
        #expect(imported.settings.provider == .gmail)
        #expect(imported.settings.user == "me@gmail.com")
        #expect(imported.password == "pw")
    }
}

struct CLIImportMergeTests {
    @Test func keepsLanguageAndTrimsAddresses() {
        let imported = AppSettings(kindleEmail: " a@kindle.com ", provider: .gmail, user: " me@gmail.com\n",
                                   from: "  ", language: "en")
        let current = AppSettings(kindleEmail: "old@kindle.com", provider: .icloud, user: "old", language: nil)
        let merged = CLIConfigImporter.Imported(settings: imported, password: "pw").applied(to: current)
        #expect(merged.kindleEmail == "a@kindle.com")
        #expect(merged.user == "me@gmail.com")
        #expect(merged.provider == .gmail)
        #expect(merged.from == nil)
        #expect(merged.language == nil)
    }

    @Test func trimsNonEmptyFrom() {
        let imported = AppSettings(user: "u", from: " me@x.com ")
        let merged = CLIConfigImporter.Imported(settings: imported, password: nil).applied(to: AppSettings(language: "fr"))
        #expect(merged.from == "me@x.com")
        #expect(merged.language == "fr")
    }
}
