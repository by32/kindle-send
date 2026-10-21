import Foundation
import Testing
@testable import KindleSendKit

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
            url == Self.withImages ? Data(count: 30 * Self.mb) : Data(count: Self.mb)
        }
        let attachment = try await EditionDownloader(http: http).download(Self.pride, maxBytes: 20 * Self.mb)

        #expect(attachment.data.count == Self.mb)
        #expect(attachment.filename == "Pride and Prejudice - Austen.epub")
        #expect(attachment.mimeType == "application/epub+zip")
        #expect(await http.requests == [Self.withImages, Self.noImages])
    }

    @Test func smallEnoughSkipsFallback() async throws {
        let http = FakeHTTPClient { _ in Data(count: Self.mb) }
        _ = try await EditionDownloader(http: http).download(Self.pride, maxBytes: 20 * Self.mb)
        #expect(await http.requests == [Self.withImages])
    }

    @Test func oversizeEvenWithoutImages() async {
        let http = FakeHTTPClient { _ in Data(count: 30 * Self.mb) }
        let error = await #expect(throws: DownloadError.self) {
            try await EditionDownloader(http: http).download(Self.pride, maxBytes: 20 * Self.mb)
        }
        #expect(error == .tooLarge(bytes: 30 * Self.mb, cap: 20 * Self.mb))
        #expect(error?.errorDescription == "Too large to email (30.0 MB > 20 MB cap)")
    }

    @Test func seUsesEpubURL() async throws {
        let edition = Edition(
            id: "se:/ebooks/mary-shelley/frankenstein", source: .standardEbooks, title: "Frankenstein",
            authors: ["Mary Shelley"], languages: ["en"], subjects: [], coverURL: Self.cover)
        let http = FakeHTTPClient { _ in Data(count: Self.mb) }
        let attachment = try await EditionDownloader(http: http).download(edition, maxBytes: 20 * Self.mb)

        #expect(await http.requests == [StandardEbooksParser.epubURL(for: edition)])
        #expect(attachment.filename == "Frankenstein - Shelley.epub")
    }

    @Test func seOversizeHasNoFallback() async {
        let edition = Edition(
            id: "se:/ebooks/mary-shelley/frankenstein", source: .standardEbooks, title: "Frankenstein",
            authors: ["Mary Shelley"], languages: ["en"], subjects: [], coverURL: Self.cover)
        let http = FakeHTTPClient { _ in Data(count: 30 * Self.mb) }
        await #expect(throws: DownloadError.tooLarge(bytes: 30 * Self.mb, cap: 20 * Self.mb)) {
            try await EditionDownloader(http: http).download(edition, maxBytes: 20 * Self.mb)
        }
        #expect(await http.requests.count == 1)
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
}
