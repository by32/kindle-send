import Foundation
import Testing
@testable import KindleSendKit

/// `count` bytes starting with the ZIP local-file-header magic, like a real EPUB.
func epubData(_ count: Int) -> Data {
    var data = Data(count: count)
    data.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x03, 0x04])
    return data
}

@Suite struct EditionDownloaderTests {
    private static let mb = 1_048_576
    private static let cover = URL(string: "https://example.com/c.jpg")!

    private static let pride = Edition(
        id: "pg:1342", source: .gutenberg, title: "Pride and Prejudice", authors: ["Jane Austen"],
        languages: ["en"], subjects: [], coverURL: cover)

    private static let withImages = URL(string: "https://www.gutenberg.org/ebooks/1342.epub3.images")!
    private static let noImages = URL(string: "https://www.gutenberg.org/ebooks/1342.epub.noimages")!

    @Test func noImagesFallback() async throws {
        let http = FakeHTTPClient { url in
            url == Self.withImages ? epubData(30 * Self.mb) : epubData(Self.mb)
        }
        let attachment = try await EditionDownloader(http: http).download(Self.pride, maxBytes: 20 * Self.mb)

        #expect(attachment.data.count == Self.mb)
        #expect(attachment.filename == "Pride and Prejudice - Austen.epub")
        #expect(attachment.mimeType == "application/epub+zip")
        #expect(await http.requests == [Self.withImages, Self.noImages])
    }

    @Test func smallEnoughSkipsFallback() async throws {
        let http = FakeHTTPClient { _ in epubData(Self.mb) }
        _ = try await EditionDownloader(http: http).download(Self.pride, maxBytes: 20 * Self.mb)
        #expect(await http.requests == [Self.withImages])
    }

    @Test func oversizeEvenWithoutImages() async {
        let http = FakeHTTPClient { _ in epubData(30 * Self.mb) }
        let error = await #expect(throws: DownloadError.self) {
            try await EditionDownloader(http: http).download(Self.pride, maxBytes: 20 * Self.mb)
        }
        // The reported size is the encoded message size that is compared against the cap.
        #expect(error == .tooLarge(bytes: Batching.singleMessageSize(30 * Self.mb), cap: 20 * Self.mb))
        #expect(error?.errorDescription == "Too large to email (41.1 MB > 20 MB cap)")
    }

    @Test func seUsesEpubURL() async throws {
        let edition = Edition(
            id: "se:/ebooks/mary-shelley/frankenstein", source: .standardEbooks, title: "Frankenstein",
            authors: ["Mary Shelley"], languages: ["en"], subjects: [], coverURL: Self.cover)
        let http = FakeHTTPClient { _ in epubData(Self.mb) }
        let attachment = try await EditionDownloader(http: http).download(edition, maxBytes: 20 * Self.mb)

        #expect(await http.requests == [StandardEbooksParser.epubURL(for: edition)])
        #expect(attachment.filename == "Frankenstein - Shelley.epub")
    }

    @Test func seOversizeHasNoFallback() async {
        let edition = Edition(
            id: "se:/ebooks/mary-shelley/frankenstein", source: .standardEbooks, title: "Frankenstein",
            authors: ["Mary Shelley"], languages: ["en"], subjects: [], coverURL: Self.cover)
        let http = FakeHTTPClient { _ in epubData(30 * Self.mb) }
        await #expect(throws: DownloadError.tooLarge(bytes: Batching.singleMessageSize(30 * Self.mb), cap: 20 * Self.mb)) {
            try await EditionDownloader(http: http).download(edition, maxBytes: 20 * Self.mb)
        }
        #expect(await http.requests.count == 1)
    }

    @Test func htmlInsteadOfEpubIsRejected() async {
        let http = FakeHTTPClient { _ in Data("<!DOCTYPE html><html><body>Too many requests</body></html>".utf8) }
        let error = await #expect(throws: DownloadError.self) {
            try await EditionDownloader(http: http).download(Self.pride, maxBytes: 20 * Self.mb)
        }
        #expect(error == .notAnEpub)
        #expect(error?.errorDescription == "Download wasn't an EPUB (the site may be rate-limiting; try again later)")
    }

    @Test func emptyDownloadIsRejected() async {
        let http = FakeHTTPClient { _ in Data() }
        await #expect(throws: DownloadError.notAnEpub) {
            try await EditionDownloader(http: http).download(Self.pride, maxBytes: 20 * Self.mb)
        }
    }

    @Test func httpStatusMapsToDownloadError() async {
        let http = FakeHTTPClient { url in throw HTTPError.status(404, url) }
        await #expect(throws: DownloadError.http(404)) {
            try await EditionDownloader(http: http).download(Self.pride, maxBytes: 20 * Self.mb)
        }
    }

    @Test func otherErrorsPassThrough() async {
        struct Boom: Error, Equatable {}
        let http = FakeHTTPClient { _ in throw Boom() }
        await #expect(throws: Boom()) {
            try await EditionDownloader(http: http).download(Self.pride, maxBytes: 20 * Self.mb)
        }
    }

    @Test func filenameSanitizesSlashAndColon() {
        let edition = Edition(
            id: "pg:1", source: .gutenberg, title: "Either/Or: A Fragment", authors: ["Søren Kierkegaard"],
            languages: ["en"], subjects: [], coverURL: Self.cover)
        #expect(EditionDownloader.filename(for: edition) == "Either-Or- A Fragment - Kierkegaard.epub")
    }

    @Test func filenameScrubsControlCharactersAndTruncatesTitle() {
        let nasty = Edition(
            id: "pg:1", source: .gutenberg, title: "Evil\r\nBcc: x@y.z", authors: ["A\nB Poe"],
            languages: ["en"], subjects: [], coverURL: Self.cover)
        #expect(EditionDownloader.filename(for: nasty) == "Evil Bcc- x@y.z - Poe.epub")

        let long = Edition(
            id: "pg:2", source: .gutenberg, title: String(repeating: "T", count: 500), authors: ["Jane Austen"],
            languages: ["en"], subjects: [], coverURL: Self.cover)
        #expect(EditionDownloader.filename(for: long) == String(repeating: "T", count: 120) + " - Austen.epub")
    }

    @Test func overheadCountsTowardCap() async {
        // Raw bytes whose base64 alone fits the cap, but not with MIME overhead.
        let cap = 1_048_576
        let size = 765_000 // encoded ~1,046,800 bytes
        #expect(Batching.encodedSize(size) <= cap)
        let http = FakeHTTPClient { _ in epubData(size) }
        await #expect(throws: DownloadError.self) {
            try await EditionDownloader(http: http).download(Self.pride, maxBytes: cap)
        }
    }
}
