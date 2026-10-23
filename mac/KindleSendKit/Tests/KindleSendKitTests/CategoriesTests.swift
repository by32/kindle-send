import Foundation
import Testing
@testable import KindleSendKit

@Suite struct CategoriesTests {
    private func edition(_ source: Source, subjects: [String]) -> Edition {
        Edition(
            id: "pg:1", source: source, title: "T", authors: ["A"], languages: ["en"],
            subjects: subjects, coverURL: URL(string: "https://example.com/c.jpg")!)
    }

    @Test func historyPrefixMatches() {
        let e = edition(.gutenberg, subjects: ["Category: History - American"])
        #expect(BookCategory.history.matches(e))
        #expect(!BookCategory.poetry.matches(e))
    }

    @Test func popularMatchesEverything() {
        #expect(BookCategory.popular.matches(edition(.gutenberg, subjects: [])))
    }

    @Test func standardEbooksSlugsMatchExactly() {
        #expect(BookCategory.scienceFiction.matches(edition(.standardEbooks, subjects: ["science-fiction"])))
        #expect(!BookCategory.history.matches(edition(.standardEbooks, subjects: ["history-of-art"])))
    }

    @Test func titles() {
        #expect(BookCategory.allCases.map(\.title) == [
            "Popular", "Fiction", "Science Fiction", "Mystery", "Philosophy", "History", "Poetry", "Children's",
        ])
    }

    @Test func workMatchesWhenAnyEditionDoes() {
        let se = edition(.standardEbooks, subjects: ["science-fiction"])
        var pg = edition(.gutenberg, subjects: ["Category: Novels"])
        pg.id = "pg:2"
        let work = Work(id: "k", editions: [se, pg])
        #expect(BookCategory.fiction.matches(work))
        #expect(BookCategory.scienceFiction.matches(work))
        #expect(!BookCategory.poetry.matches(work))
    }

    @Test func mixedGutenbergSubjectsAndShelvesMatch() {
        let e = edition(.gutenberg, subjects: ["Monsters -- Fiction", "Science fiction", "Category: Short Stories"])
        #expect(BookCategory.fiction.matches(e))
    }

    @Test func bareHistorySubjectDoesNotMatchGutenberg() {
        #expect(!BookCategory.history.matches(edition(.gutenberg, subjects: ["history"])))
    }
}
