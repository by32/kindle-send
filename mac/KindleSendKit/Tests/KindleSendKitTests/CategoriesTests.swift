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
        #expect(Category.history.matches(e))
        #expect(!Category.poetry.matches(e))
    }

    @Test func popularMatchesEverything() {
        #expect(Category.popular.matches(edition(.gutenberg, subjects: [])))
    }

    @Test func standardEbooksSlugsMatchExactly() {
        #expect(Category.scienceFiction.matches(edition(.standardEbooks, subjects: ["science-fiction"])))
        #expect(!Category.history.matches(edition(.standardEbooks, subjects: ["history-of-art"])))
    }

    @Test func titles() {
        #expect(Category.allCases.map(\.title) == [
            "Popular", "Fiction", "Science Fiction", "Mystery", "Philosophy", "History", "Poetry", "Children's",
        ])
    }
}
