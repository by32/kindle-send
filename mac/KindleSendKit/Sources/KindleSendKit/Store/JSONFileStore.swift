import Foundation
import os

/// Persists one Codable value as JSON. Writes are atomic. A missing file loads as `nil`; a file that
/// exists but cannot be decoded is renamed to `<name>.corrupt-<unix time>` (so the next save cannot
/// destroy it) and also loads as `nil`.
struct JSONFileStore<T: Codable>: Sendable where T: Sendable {
    static var logger: Logger { Logger(subsystem: "com.by32.KindleSend", category: "store") }
    let fileURL: URL

    func load() -> T? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let value = try? decoder.decode(T.self, from: data) { return value }
        let quarantine = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(Int(Date.now.timeIntervalSince1970))")
        do {
            try FileManager.default.moveItem(at: fileURL, to: quarantine)
            Self.logger.error("Corrupt \(fileURL.lastPathComponent, privacy: .public); moved to \(quarantine.lastPathComponent, privacy: .public)")
        } catch {
            Self.logger.error("Corrupt \(fileURL.lastPathComponent, privacy: .public) and could not quarantine it: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    func save(_ value: T) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }

    /// Saves, returning the failure text (and logging it) instead of throwing.
    func trySave(_ value: T) -> String? {
        do {
            try save(value)
            return nil
        } catch {
            Self.logger.error("Saving \(fileURL.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }
}
