import Foundation
import Testing
@testable import KindleSendKit

@Suite struct WorkGrouperTests {
    private func edition(
        _ id: String, _ source: Source, _ title: String, _ author: String, downloads: Int = 0
    ) -> Edition {
        Edition(
            id: id, source: source, title: title, authors: [author], languages: ["en"],
            subjects: [], downloads: downloads, coverURL: URL(string: "https://example.com/c.jpg")!)
    }

    @Test func seEditionIsDefault() {
        let pg = edition("pg:84", .gutenberg, "Frankenstein; Or, The Modern Prometheus", "Mary Wollstonecraft Shelley", downloads: 9000)
        let se = edition("se:/ebooks/mary-shelley/frankenstein", .standardEbooks, "Frankenstein", "Mary Shelley")
        let works = WorkGrouper.group([pg, se])
        #expect(works.count == 1)
        #expect(works[0].defaultEdition.source == .standardEbooks)
        #expect(works[0].editions.map(\.id) == [se.id, pg.id])
        #expect(works[0].id == matchKey(title: "Frankenstein", primaryAuthor: "Mary Shelley"))
    }

    @Test func mostDownloadedGutenbergIsDefaultWithoutSE() {
        let low = edition("pg:1", .gutenberg, "Emma", "Jane Austen", downloads: 10)
        let high = edition("pg:2", .gutenberg, "Emma", "Jane Austen", downloads: 500)
        let works = WorkGrouper.group([low, high])
        #expect(works.count == 1)
        #expect(works[0].defaultEdition.id == "pg:2")
    }

    @Test func distinctWorksStaySeparate() {
        let works = WorkGrouper.group([
            edition("pg:1", .gutenberg, "Emma", "Jane Austen"),
            edition("pg:2", .gutenberg, "Persuasion", "Jane Austen"),
            edition("pg:3", .gutenberg, "Emma", "Someone Else"),
        ])
        #expect(works.count == 3)
    }

    @Test func embeddedNewlineInTitleDoesNotSplitGroup() {
        let a = edition("pg:1", .gutenberg, "Pride and\r\nPrejudice", "Jane Austen", downloads: 1)
        let b = edition("pg:2", .gutenberg, "Pride and Prejudice", "Jane Austen", downloads: 2)
        #expect(WorkGrouper.group([a, b]).count == 1)
    }

    @Test func missingAuthorStillGroups() {
        var a = edition("pg:1", .gutenberg, "Beowulf", "x")
        a.authors = []
        var b = edition("pg:2", .gutenberg, "Beowulf", "x")
        b.authors = []
        #expect(WorkGrouper.group([a, b]).count == 1)
    }
}
