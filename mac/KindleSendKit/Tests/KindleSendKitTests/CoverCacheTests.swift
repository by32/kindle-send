import Foundation
import Synchronization
import Testing
@testable import KindleSendKit

/// Holds every request until `release()`, counting requests and observing cancellation.
final class GatedHTTPClient: HTTPClient {
    private let state = Mutex((requests: 0, released: false, cancelled: 0))
    private let body: Data

    init(body: Data) { self.body = body }

    var requests: Int { state.withLock { $0.requests } }
    var cancelled: Int { state.withLock { $0.cancelled } }
    func release() { state.withLock { $0.released = true } }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        state.withLock { $0.requests += 1 }
        do {
            while !state.withLock({ $0.released }) { try await Task.sleep(for: .milliseconds(2)) }
        } catch {
            state.withLock { $0.cancelled += 1 }
            throw error
        }
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct CoverCacheTests {
    private let url = URL(string: "https://www.gutenberg.org/cache/epub/84/pg84.cover.medium.jpg")!
    private let jpeg = Data("jpeg bytes".utf8)

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<2000 where !condition() { try await Task.sleep(for: .milliseconds(1)) }
        #expect(condition())
    }

    @Test func keyIsSHA1OfTheURL() {
        #expect(CoverCache.fileName(for: url) == "7dd74f49e4a57e4faad537ac6af776a8968b66c4.jpg")
    }

    @Test func fileLivesInCoversUnderTheDataDirectory() {
        let dataDir = URL(fileURLWithPath: "/tmp/ks-data", isDirectory: true)
        let cache = CoverCache(dataDirectory: dataDir, http: FakeHTTPClient { _ in Data() })
        #expect(cache.fileURL(for: url).path == "/tmp/ks-data/covers/7dd74f49e4a57e4faad537ac6af776a8968b66c4.jpg")
    }

    @Test func downloadsOnceThenServesFromDisk() async throws {
        let dataDir = try scratch()
        let http = FakeHTTPClient { _ in Data("jpeg bytes".utf8) }
        let cache = CoverCache(dataDirectory: dataDir, http: http)

        #expect(try await cache.data(for: url) == jpeg)
        #expect(try Data(contentsOf: cache.fileURL(for: url)) == jpeg)
        #expect(try await cache.data(for: url) == jpeg)
        #expect(await http.requests.count == 1)

        // A fresh cache (a relaunch) reads the file without the network.
        let relaunchHTTP = FakeHTTPClient { _ in Data() }
        let relaunched = CoverCache(dataDirectory: dataDir, http: relaunchHTTP)
        #expect(try await relaunched.data(for: url) == jpeg)
        #expect(await relaunchHTTP.requests.isEmpty)
    }

    @Test func concurrentLoadsOfOneURLShareOneDownload() async throws {
        let http = GatedHTTPClient(body: jpeg)
        let cache = CoverCache(dataDirectory: try scratch(), http: http)

        async let first = cache.data(for: url)
        async let second = cache.data(for: url)
        try await waitUntil { http.requests >= 1 }
        try await Task.sleep(for: .milliseconds(20))
        http.release()

        #expect(try await first == jpeg)
        #expect(try await second == jpeg)
        #expect(http.requests == 1)
    }

    @Test func downloadIsCancelledOnlyWhenEveryCallerIsCancelled() async throws {
        let http = GatedHTTPClient(body: jpeg)
        let cache = CoverCache(dataDirectory: try scratch(), http: http)

        let a = Task { try await cache.data(for: url) }
        let b = Task { try await cache.data(for: url) }
        try await waitUntil { http.requests >= 1 }
        a.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(http.cancelled == 0)

        b.cancel()
        try await waitUntil { http.cancelled == 1 }
        await #expect(throws: CancellationError.self) { try await b.value }
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL(for: url).path))

        // A later caller starts a fresh download.
        http.release()
        #expect(try await cache.data(for: url) == jpeg)
        #expect(http.requests == 2)
    }

    @Test func failureIsNotCachedAndRetries() async throws {
        let fails = Mutex(true)
        let http = FakeHTTPClient { url in
            if fails.withLock({ $0 }) { throw HTTPError.status(404, url) }
            return Data("jpeg bytes".utf8)
        }
        let cache = CoverCache(dataDirectory: try scratch(), http: http)

        await #expect(throws: HTTPError.status(404, url)) { try await cache.data(for: url) }
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL(for: url).path))
        fails.withLock { $0 = false }
        #expect(try await cache.data(for: url) == jpeg)
    }

    @Test func placeholderHueIsStableAndSpread() {
        let hue = CoverPlaceholder.hue(for: "Frankenstein")
        #expect(hue >= 0 && hue < 1)
        // Pinned: a per-launch-randomized hash (String.hashValue) would fail this across runs.
        #expect(hue == CoverPlaceholder.hue(for: "Frankenstein"))
        #expect(hue == 37.0 / 360)  // FNV-1a("Frankenstein") % 360, computed independently
        let titles = ["Pride and Prejudice", "Moby Dick", "Dracula", "Walden", "The Odyssey", "Jane Eyre"]
        #expect(Set(titles.map { Int(CoverPlaceholder.hue(for: $0) * 36) }).count >= 4)
    }
}
