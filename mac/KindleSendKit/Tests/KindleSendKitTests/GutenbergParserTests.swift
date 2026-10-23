import Foundation
import Testing
@testable import KindleSendKit

private func fixture(_ name: String, _ ext: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct GutenbergParserTests {
    private func editions() throws -> [Edition] {
        try GutenbergCatalogParser.parse(csv: fixture("pg_catalog_sample", "csv"))
    }

    @Test func parsesQuotedMultilineAndSkipsNonText() throws {
        let all = try editions()
        #expect(all.count == 9)  // 10 data rows, one is Sound
        #expect(!all.contains { $0.id == "pg:3002" })
        let seas = try #require(all.first { $0.id == "pg:464" })
        #expect(seas.title.hasPrefix("In the South Seas"))
        #expect(seas.title.contains { $0.isNewline })
        #expect(seas.title.contains("the Yacht \"Casco\" (1888)"))
    }

    @Test func mapsFields() throws {
        let pride = try #require(try editions().first { $0.id == "pg:1342" })
        #expect(pride.title == "Pride and Prejudice")
        #expect(pride.source == .gutenberg)
        #expect(pride.authors == ["Jane Austen"])
        #expect(pride.languages == ["en"])
        #expect(pride.coverURL.absoluteString == "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg")
        #expect(pride.downloads == 0)
        #expect(pride.issued == "1998-06-01")
        #expect(pride.credits == nil)
        #expect(pride.subjects.contains("England -- Fiction"))
        #expect(pride.subjects.contains("Category: Novels"))
    }

    @Test func multipleLanguages() throws {
        let right = try #require(try editions().first { $0.id == "pg:1981" })
        #expect(right.languages == ["en", "fr"])
    }

    @Test func translatorGoesToCredits() throws {
        let war = try #require(try editions().first { $0.id == "pg:2600" })
        #expect(war.authors == ["Leo Tolstoy"])
        #expect(war.credits == "Aylmer Maude (Translator); Louise Maude (Translator)")
        let eyre = try #require(try editions().first { $0.id == "pg:1260" })
        #expect(eyre.authors == ["Charlotte Brontë"])
        #expect(eyre.credits == "F. H. Townsend (Illustrator)")
    }

    @Test func rejectsUnexpectedHeader() {
        #expect(throws: GutenbergCatalogError.self) {
            try GutenbergCatalogParser.parse(csv: "a,b\n1,2\n")
        }
    }

    @Test func editorOnlyRowFallsBackToFirstCredit() throws {
        let jargon = try #require(try editions().first { $0.id == "pg:38" })
        #expect(jargon.authors == ["Eric S. Raymond"])
        #expect(jargon.credits == "Eric S. Raymond (Editor); Guy L. Steele (Editor)")
    }

    @Test func popularityUsesOnlyThirtyDaySection() throws {
        let scores = GutenbergPopularityParser.parse(html: try fixture("top1000_sample", "html"))
        #expect(scores[2701] == 190821)  // yesterday says 7134, 7 days says 53137
        #expect(scores[1342] == 186807)
        #expect(scores[79253] == nil)  // yesterday-only
        #expect(scores.count == 3)
    }

    @Test func popularityWithoutThirtyDaySectionIsEmpty() {
        #expect(GutenbergPopularityParser.parse(html: "<ol><li><a href=\"/ebooks/1\">A by B (5)</a></li></ol>").isEmpty)
    }
}
