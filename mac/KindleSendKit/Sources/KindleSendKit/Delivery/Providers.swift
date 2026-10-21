import Foundation

public enum SMTPSecurity: Sendable, Codable {
    /// TLS from the first byte (port 465).
    case implicitTLS
    /// Plain connection upgraded with the STARTTLS command (port 587 and anything else).
    case startTLS
}

public struct SMTPAccount: Sendable, Codable, Equatable {
    public var host: String
    public var port: Int
    public var user: String
    public var from: String
    /// Largest message the provider accepts, in bytes.
    public var maxBytes: Int

    public var security: SMTPSecurity { port == 465 ? .implicitTLS : .startTLS }

    public init(host: String, port: Int, user: String, from: String, maxBytes: Int) {
        self.host = host
        self.port = port
        self.user = user
        self.from = from
        self.maxBytes = maxBytes
    }
}

public enum Provider: String, CaseIterable, Codable, Sendable {
    case icloud, gmail, fastmail, yahoo, custom

    private static let megabyte = 1_048_576
    /// Per-email cap for a user-supplied server.
    public static let customMaxBytes = 50 * megabyte

    public var displayName: String {
        switch self {
        case .icloud: "iCloud Mail"
        case .gmail: "Gmail"
        case .fastmail: "Fastmail"
        case .yahoo: "Yahoo Mail"
        case .custom: "Other SMTP server"
        }
    }

    /// Host, port and per-email cap; nil for `.custom`, whose host and port the user supplies.
    public var preset: (host: String, port: Int, maxBytes: Int)? {
        switch self {
        case .icloud: ("smtp.mail.me.com", 587, 20 * Self.megabyte)
        case .gmail: ("smtp.gmail.com", 465, 25 * Self.megabyte)
        case .fastmail: ("smtp.fastmail.com", 465, 50 * Self.megabyte)
        case .yahoo: ("smtp.mail.yahoo.com", 465, 25 * Self.megabyte)
        case .custom: nil
        }
    }

    /// Where the user creates an app-specific password.
    public var appPasswordHelpURL: URL? {
        switch self {
        case .icloud: URL(string: "https://account.apple.com")
        case .gmail: URL(string: "https://myaccount.google.com/apppasswords")
        case .fastmail: URL(string: "https://app.fastmail.com/settings/security/apppasswords")
        case .yahoo: URL(string: "https://login.yahoo.com/myaccount/security/app-password")
        case .custom: nil
        }
    }
}
