import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    static let defaultsKey = "settings.v1"
    /// The custom server's port when none is set (STARTTLS), as in `kindle_send.py`.
    public static let defaultCustomPort = 587

    public var kindleEmail: String
    public var provider: Provider
    public var user: String
    public var from: String?
    public var customHost: String?
    public var customPort: Int?
    /// ISO language code to filter the catalog by; nil means all languages.
    public var language: String?

    public init(kindleEmail: String = "", provider: Provider = .icloud, user: String = "",
                from: String? = nil, customHost: String? = nil, customPort: Int? = nil,
                language: String? = Locale.current.language.languageCode?.identifier) {
        self.kindleEmail = kindleEmail
        self.provider = provider
        self.user = user
        self.from = from
        self.customHost = customHost
        self.customPort = customPort
        self.language = language
    }

    /// The SMTP account these settings describe; nil while anything required is missing.
    public var account: SMTPAccount? {
        guard !user.isEmpty else { return nil }
        let sender = from.flatMap { $0.isEmpty ? nil : $0 } ?? user
        if let preset = provider.preset {
            return SMTPAccount(host: preset.host, port: preset.port, user: user, from: sender, maxBytes: preset.maxBytes)
        }
        guard let host = customHost, !host.isEmpty else { return nil }
        return SMTPAccount(host: host, port: customPort ?? Self.defaultCustomPort, user: user, from: sender, maxBytes: Provider.customMaxBytes)
    }

    public var isValidKindleEmail: Bool {
        let e = kindleEmail.lowercased()
        return e.hasSuffix("@kindle.com") && e.filter { $0 == "@" }.count == 1 && e.count > "@kindle.com".count
    }

    public static func load(from defaults: UserDefaults) -> AppSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
