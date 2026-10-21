import Testing
@testable import KindleSendKit

@Suite struct NormalizeTests {
    @Test func dropsLeadingArticleAndFoldsPunctuation() {
        #expect(
            matchKey(title: "The Count of Monte-Cristo", primaryAuthor: "Alexandre Dumas")
                == matchKey(title: "count of monte cristo", primaryAuthor: "alexandre dumas"))
    }

    @Test func cutsSubtitleAndUsesFirstLastAuthorTokens() {
        #expect(
            matchKey(title: "Frankenstein; Or, The Modern Prometheus", primaryAuthor: "Mary Wollstonecraft Shelley")
                == matchKey(title: "Frankenstein", primaryAuthor: "Mary Shelley"))
    }

    @Test func differentAuthorsDiffer() {
        #expect(
            matchKey(title: "Emma", primaryAuthor: "Jane Austen")
                != matchKey(title: "Emma", primaryAuthor: "Unknown"))
    }

    @Test func foldsDiacriticsAndPunctuation() {
        #expect(foldForSearch("Brontë, Émile") == "bronte emile")
    }

    @Test func displayAuthorFromGutenberg() {
        #expect(displayAuthor(fromGutenberg: "Austen, Jane, 1775-1817") == "Jane Austen")
        #expect(displayAuthor(fromGutenberg: "Homer, 751? BCE-651? BCE") == "Homer")
        #expect(displayAuthor(fromGutenberg: "Townsend, F. H. (Frederick Henry), 1868-1920") == "F. H. Townsend")
        #expect(displayAuthor(fromGutenberg: "Wells, H. G. (Herbert George), 1866-1946") == "H. G. Wells")
    }
}
