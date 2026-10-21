import CryptoKit
import Foundation

/// Cover images on disk at `{data dir}/covers/{sha1(url)}.jpg`, downloaded on first use. Concurrent
/// requests for one URL share a single download, which is cancelled only once every caller waiting
/// on it has been cancelled. Disk and network work never runs on the caller's actor.
public actor CoverCache {
    public nonisolated let directory: URL
    private let http: any HTTPClient
    private var inFlight: [URL: Load] = [:]

    private struct Load {
        let id = UUID()
        let task: Task<Data, Error>
        /// Callers still waiting and not cancelled.
        var waiters = 1
    }

    public init(dataDirectory: URL, http: any HTTPClient) {
        directory = dataDirectory.appendingPathComponent("covers", isDirectory: true)
        self.http = http
    }

    public nonisolated static func fileName(for url: URL) -> String {
        let digest = Insecure.SHA1.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    public nonisolated func fileURL(for url: URL) -> URL {
        directory.appendingPathComponent(Self.fileName(for: url))
    }

    /// The cover's bytes, from disk or downloaded (and then saved). Throws `CancellationError` when
    /// the caller is cancelled before the download finishes.
    public func data(for url: URL) async throws -> Data {
        let load: Load
        if var existing = inFlight[url] {
            existing.waiters += 1
            inFlight[url] = existing
            load = existing
        } else {
            let file = fileURL(for: url)
            let http = http
            load = Load(task: Task.detached(priority: .utility) {
                try await Self.fetch(url, into: file, http: http)
            })
            inFlight[url] = load
        }
        let id = load.id
        return try await withTaskCancellationHandler {
            let result = await load.task.result
            if inFlight[url]?.id == id { inFlight[url] = nil }
            try Task.checkCancellation()
            return try result.get()
        } onCancel: {
            Task { await self.abandon(url, id: id) }
        }
    }

    private func abandon(_ url: URL, id: UUID) {
        guard var load = inFlight[url], load.id == id else { return }
        load.waiters -= 1
        if load.waiters > 0 {
            inFlight[url] = load
        } else {
            load.task.cancel()
            inFlight[url] = nil
        }
    }

    private static func fetch(_ url: URL, into file: URL, http: any HTTPClient) async throws -> Data {
        if let cached = try? Data(contentsOf: file) { return cached }
        let (data, _) = try await http.data(from: url)
        try Task.checkCancellation()
        // A failed write only costs a re-download next time.
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }
}

/// The card shown while a cover is loading or when it is missing.
public enum CoverPlaceholder {
    /// A hue in 0..<1 from a stable FNV-1a hash of the title (`hashValue` changes every launch).
    public static func hue(for title: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in title.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Double(hash % 360) / 360
    }
}
