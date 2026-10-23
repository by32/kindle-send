import Testing
@testable import KindleSendKit

@Suite struct TypoToleranceTests {
    @Test func trigrams() {
        #expect(TypoTolerance.trigrams("Emma") == ["emm", "mma"])
        #expect(TypoTolerance.trigrams("") == [])
    }

    @Test func similarity() {
        #expect(TypoTolerance.similarity("dostoyevsky", "dostoevsky") > 0.4)
        #expect(TypoTolerance.similarity("dostoyevsky", "austen") < 0.1)
        #expect(TypoTolerance.similarity("austen", "austen") == 1.0)
    }
}
