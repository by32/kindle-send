import Foundation

/// One-time import of the Python CLI's `~/.config/kindle-send/config.toml`.
public enum CLIConfigImporter {
    public struct Imported: Equatable {
        public var settings: AppSettings
        public var password: String?

        /// The imported account over `current`: keeps the user's language choice and trims the
        /// addresses (an empty From becomes nil).
        public func applied(to current: AppSettings) -> AppSettings {
            var s = settings
            s.language = current.language
            s.kindleEmail = s.kindleEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            s.user = s.user.trimmingCharacters(in: .whitespacesAndNewlines)
            s.from = s.from?.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.from?.isEmpty == true { s.from = nil }
            return s
        }
    }

    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/kindle-send/config.toml")

    private enum Value: Equatable { case string(String), int(Int) }
    private typealias Tables = [String: [String: Value]]

    public static func parse(toml: String) -> Imported? {
        guard var tables = tables(from: toml) else { return nil }
        var top = tables[""] ?? [:]
        migrateLegacy(&top, into: &tables)

        let name = (string(top["provider"]) ?? "gmail").lowercased()
        let provider: Provider
        let section: String
        if name == "smtp" { provider = .custom; section = "smtp" }
        else if let known = Provider(rawValue: name), known != .custom { provider = known; section = name }
        else { return nil }

        let table = tables[section] ?? [:]
        var settings = AppSettings(kindleEmail: string(top["kindle_email"]) ?? "", provider: provider,
                                   user: string(table["user"]) ?? "")
        settings.from = string(table["from"])
        if provider == .custom {
            settings.customHost = string(table["host"])
            if case .int(let port)? = table["port"] { settings.customPort = port }
        }
        return Imported(settings: settings, password: string(table["password"]))
    }

    public static func load(from url: URL = defaultURL) -> Imported? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { parse(toml: $0) }
    }

    /// Mirrors `_read_toml`: first-version configs used flat `smtp_*` keys.
    private static func migrateLegacy(_ top: inout [String: Value], into tables: inout Tables) {
        guard let user = top.removeValue(forKey: "smtp_user") else { return }
        let host = string(top.removeValue(forKey: "smtp_host")) ?? "smtp.gmail.com"
        let port = top.removeValue(forKey: "smtp_port")
        let name = Provider.allCases.first { $0.preset?.host == host }?.rawValue ?? "smtp"
        var section: [String: Value] = ["user": user]
        if name == "smtp" { section["host"] = .string(host); section["port"] = port ?? .int(587) }
        if let password = top.removeValue(forKey: "smtp_password") { section["password"] = password }
        if let from = top.removeValue(forKey: "from_addr") { section["from"] = from }
        if tables[name] == nil { tables[name] = section }
        if top["provider"] == nil { top["provider"] = .string(name) }
    }

    private static func string(_ v: Value?) -> String? {
        if case .string(let s)? = v { return s }
        return nil
    }

    /// Top-level keys land in the "" table. Returns nil on a line it cannot read.
    private static func tables(from text: String) -> Tables? {
        var tables: Tables = [:]
        var current = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else { return nil }
                current = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                guard !current.isEmpty, rest.isEmpty || rest.hasPrefix("#") else { return nil }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard let value = value(String(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))) else { return nil }
            tables[current, default: [:]][key] = value
        }
        return tables
    }

    private static func value(_ rest: String) -> Value? {
        if rest.hasPrefix("\"") {
            // TOML basic strings use JSON-style escapes; decode just the leading string literal.
            var end = rest.index(after: rest.startIndex)
            var escaped = false
            while end < rest.endIndex {
                let c = rest[end]
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { break }
                end = rest.index(after: end)
            }
            guard end < rest.endIndex, trailingIsEmpty(rest[rest.index(after: end)...]),
                  let data = String(rest[...end]).data(using: .utf8),
                  let s = try? JSONDecoder().decode(String.self, from: data) else { return nil }
            return .string(s)
        }
        if rest.hasPrefix("'") {
            guard let end = rest.dropFirst().firstIndex(of: "'"), trailingIsEmpty(rest[rest.index(after: end)...]) else { return nil }
            return .string(String(rest[rest.index(after: rest.startIndex)..<end]))
        }
        let token = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
        return Int(token).map(Value.int)
    }

    private static func trailingIsEmpty(_ s: Substring) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.hasPrefix("#")
    }
}
