import Foundation
import Testing
@testable import KindleSendKit

struct AppSettingsTests {
    @Test func kindleValidation() {
        #expect(AppSettings(kindleEmail: "a@kindle.com").isValidKindleEmail)
        #expect(!AppSettings(kindleEmail: "a@gmail.com").isValidKindleEmail)
        #expect(!AppSettings(kindleEmail: "a@@kindle.com").isValidKindleEmail)
    }

    @Test func accountFromPreset() {
        let s = AppSettings(provider: .icloud, user: "me@icloud.com")
        #expect(s.account == SMTPAccount(host: "smtp.mail.me.com", port: 587, user: "me@icloud.com",
                                         from: "me@icloud.com", maxBytes: 20 * 1_048_576))
        #expect(AppSettings(provider: .custom, user: "u").account == nil)
    }

    @Test func roundTripsThroughUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)"))
        let s = AppSettings(kindleEmail: "a@kindle.com", provider: .custom, user: "u", customHost: "h", customPort: 465, language: nil)
        s.save(to: defaults)
        #expect(AppSettings.load(from: defaults) == s)
    }
}
