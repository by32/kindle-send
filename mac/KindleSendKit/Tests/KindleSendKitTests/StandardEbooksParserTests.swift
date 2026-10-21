import Foundation
import Testing
@testable import KindleSendKit

@Suite struct StandardEbooksParserTests {
    private func editions() throws -> [Edition] {
        let url = try #require(Bundle.module.url(forResource: "se_listing_page", withExtension: "html", subdirectory: "Fixtures"))
        return StandardEbooksParser.parseListing(html: try String(contentsOf: url, encoding: .utf8))
    }

    @Test func parsesEntries() throws {
        let all = try editions()
        #expect(all.count == 3)
        let first = all[0]
        #expect(first.id == "se:/ebooks/henry-seton-merriman/suspense")
        #expect(first.source == .standardEbooks)
        #expect(first.title == "Suspense")
        #expect(first.authors == ["Henry Seton Merriman"])
        #expect(first.languages == ["en"])
        #expect(first.subjects.isEmpty)
        #expect(first.downloads == 0)
        #expect(first.credits == nil)
        #expect(first.coverURL.absoluteString.hasPrefix("https://standardebooks.org/images/covers/"))
        #expect(first.coverURL.absoluteString.hasSuffix("cover@2x.jpg"))
    }

    @Test func parsesTranslatorCreditAndAccents() throws {
        let e = try editions()[1]
        #expect(e.title == "The Emperor of Portugallia")
        #expect(e.authors == ["Selma Lagerlöf"])
        #expect(e.credits == "Velma Swanston Howard")
    }

    @Test func collectsMultipleAuthors() throws {
        let e = try editions()[2]
        #expect(e.authors == ["Samuel Taylor Coleridge", "Robert Southey"])
    }

    @Test func epubURLForTranslatorPath() throws {
        let e = try editions()[1]
        #expect(StandardEbooksParser.epubURL(for: e).absoluteString == "https://standardebooks.org/ebooks/selma-lagerlof/the-emperor-of-portugallia/velma-swanston-howard/downloads/selma-lagerlof_the-emperor-of-portugallia_velma-swanston-howard.epub?source=download")
    }

    @Test func emptyPageMeansEnd() {
        #expect(StandardEbooksParser.parseListing(html: "<html></html>").isEmpty)
    }

    @Test func decodesEntities() {
        let html = #"<li typeof="schema:Book" about="/ebooks/a/b"><img src="/images/covers/x/cover@2x.jpg"/><p><a href="/ebooks/a/b"><span property="schema:name">Pride &amp; Prejudice &#8212; I</span></a></p><p class="author"><a><span property="schema:name">A &#38; B</span></a></p></li>"#
        let e = StandardEbooksParser.parseListing(html: html)
        #expect(e.first?.title == "Pride & Prejudice \u{2014} I")
        #expect(e.first?.authors == ["A & B"])
    }

    @Test func urls() {
        #expect(StandardEbooksParser.listingURL(2).absoluteString == "https://standardebooks.org/ebooks?per-page=48&page=2")
        #expect(StandardEbooksParser.subjectURL("fiction", page: 3).absoluteString == "https://standardebooks.org/subjects/fiction?per-page=48&page=3")
    }
}
