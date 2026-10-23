import Foundation
import Testing
@testable import KindleSendKit

// Swift Testing also exports an `Attachment`.
private typealias Attachment = KindleSendKit.Attachment

@Suite struct BatchingTests {
    private static let mb = 1_048_576

    private static func item(_ index: Int, bytes: Int) -> Attachment {
        Attachment(filename: "\(index).epub", data: Data(count: bytes), mimeType: "application/epub+zip")
    }

    @Test func encodedSizeMatchesBase64WithCRLF() {
        #expect(Batching.encodedSize(0) == 0)
        #expect(Batching.encodedSize(1) == 4 + 2)
        #expect(Batching.encodedSize(57) == 76 + 2)
        #expect(Batching.encodedSize(58) == 80 + 4)
        let data = Data(count: 1000)
        let options: Data.Base64EncodingOptions = [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
        #expect(Batching.encodedSize(1000) == data.base64EncodedString(options: options).utf8.count + 2)
    }

    @Test func respectsCapAndCount() {
        let items = (0..<30).map { Self.item($0, bytes: Self.mb) }
        let cap = 20 * Self.mb
        let batches = Batching.batches(items, maxBytes: cap)

        #expect(batches.count > 1)
        for batch in batches {
            #expect(batch.reduce(0) { $0 + Batching.encodedSize($1.data.count) } < cap)
            #expect(batch.count <= 25)
        }
        #expect(batches.flatMap { $0 }.map(\.filename) == items.map(\.filename))
    }

    @Test func respectsCountWhenSmall() {
        let items = (0..<30).map { Self.item($0, bytes: 10) }
        let batches = Batching.batches(items, maxBytes: 20 * Self.mb)
        #expect(batches.map(\.count) == [25, 5])
    }

    @Test func singleOversizeGetsOwnBatch() {
        let items = [Self.item(0, bytes: 100), Self.item(1, bytes: 30 * Self.mb), Self.item(2, bytes: 100)]
        let batches = Batching.batches(items, maxBytes: 20 * Self.mb)
        #expect(batches.map { $0.map(\.filename) } == [["0.epub"], ["1.epub"], ["2.epub"]])
    }

    @Test func emptyInputGivesNoBatches() {
        #expect(Batching.batches([], maxBytes: 1000).isEmpty)
    }
}
