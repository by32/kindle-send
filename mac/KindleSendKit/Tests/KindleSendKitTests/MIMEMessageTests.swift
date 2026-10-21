import Foundation
import Testing
@testable import KindleSendKit

// Swift Testing also exports an `Attachment`.
private typealias Attachment = KindleSendKit.Attachment

@Suite struct MIMEMessageTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_792_555_445)

    private static func build(
        subject: String = "Pride and Prejudice", attachments: [Attachment]
    ) -> String {
        let data = MIMEMessage.build(
            from: "me@icloud.com", to: "kindle@kindle.com", subject: subject, attachments: attachments,
            date: fixedDate, boundary: "BOUND", messageID: "ID-1")
        return String(decoding: data, as: UTF8.self)
    }

    @Test func structure() throws {
        let payload = Data((0..<1000).map { UInt8($0 % 251) })
        let text = Self.build(attachments: [
            Attachment(filename: "Pride.epub", data: payload, mimeType: "application/epub+zip"),
            Attachment(filename: "Brontë.epub", data: Data("hi".utf8), mimeType: "application/epub+zip"),
        ])

        #expect(text.contains("Content-Type: multipart/mixed; boundary="))
        #expect(text.components(separatedBy: "Content-Disposition: attachment").count - 1 == 2)
        #expect(text.contains("filename*=UTF-8''Bront%C3%AB.epub"))
        #expect(text.contains("filename=\"Pride.epub\""))
        #expect(text.hasSuffix("--BOUND--\r\n"))

        let part = try #require(text.components(separatedBy: "--BOUND\r\n").dropFirst(2).first)
        let body = try #require(part.components(separatedBy: "\r\n\r\n").dropFirst().first)
        let lines = body.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.dropLast().allSatisfy { $0.count == 76 })
        #expect(Data(base64Encoded: lines.joined()) == payload)
    }

    @Test func crlfThroughout() {
        let text = Self.build(attachments: [Attachment(filename: "a.epub", data: Data(repeating: 7, count: 500))])
        let bare = text.replacingOccurrences(of: "\r\n", with: "")
        #expect(!bare.contains("\n"))
        #expect(!bare.contains("\r"))
    }

    @Test func standardHeaders() {
        let text = Self.build(attachments: [])
        #expect(text.contains("From: me@icloud.com\r\n"))
        #expect(text.contains("To: kindle@kindle.com\r\n"))
        #expect(text.contains("Subject: Pride and Prejudice\r\n"))
        #expect(text.contains("MIME-Version: 1.0\r\n"))
        #expect(text.contains("Message-ID: <ID-1@kindlesend.local>\r\n"))
    }

    @Test func dateHeaderIsRFC5322() throws {
        let text = Self.build(attachments: [])
        let line = try #require(text.components(separatedBy: "\r\n").first { $0.hasPrefix("Date: ") })
        let pattern = /Date: (Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} \d{2}:\d{2}:\d{2} [+-]\d{4}/
        #expect(line.wholeMatch(of: pattern) != nil, "got \(line)")
    }

    @Test func defaultMessageIDIsUnique() {
        func id() -> String {
            let data = MIMEMessage.build(from: "a@b.c", to: "d@e.f", subject: "s", attachments: [])
            let text = String(decoding: data, as: UTF8.self)
            return text.components(separatedBy: "\r\n").first { $0.hasPrefix("Message-ID: ") } ?? ""
        }
        #expect(id().hasSuffix("@kindlesend.local>"))
        #expect(id() != id())
    }

    @Test func nonASCIISubjectIsEncoded() throws {
        let text = Self.build(subject: "Brontë: Jane Eyre", attachments: [])
        let line = try #require(text.components(separatedBy: "\r\n").first { $0.hasPrefix("Subject: ") })
        #expect(line == "Subject: =?UTF-8?B?\(Data("Brontë: Jane Eyre".utf8).base64EncodedString())?=")
    }

    @Test func longNonASCIISubjectSplitsIntoShortWords() {
        let text = Self.build(subject: String(repeating: "é", count: 80), attachments: [])
        let head = text.components(separatedBy: "\r\n\r\n")[0]
        let words = head.components(separatedBy: "\r\n").filter { $0.contains("=?UTF-8?B?") }
        #expect(words.count > 1)
        #expect(words.allSatisfy { $0.count <= 76 })
    }

    @Test func textPartComesFirst() throws {
        let text = Self.build(attachments: [Attachment(filename: "a.epub", data: Data(count: 3))])
        let parts = text.components(separatedBy: "--BOUND\r\n").dropFirst()
        let first = try #require(parts.first)
        #expect(first.hasPrefix("Content-Type: text/plain; charset=utf-8\r\n"))
        #expect(first.contains("\r\n\r\nSent by Kindle Send.\r\n"))
        #expect(parts.count == 2)
    }

    @Test func crlfInFilenameCannotInjectHeaders() {
        let text = Self.build(attachments: [
            Attachment(filename: "T\r\nBcc: evil@x.com.epub", data: Data(count: 3)),
            Attachment(filename: "Ünï\r\nBcc: evil@x.com.epub", data: Data(count: 3)),
        ])
        #expect(!text.contains("\r\nBcc:"))
        #expect(text.contains("filename=\"T Bcc: evil@x.com.epub\""))
    }

    @Test func crlfInAddressesAndSubjectIsScrubbed() {
        let data = MIMEMessage.build(
            from: "a@b.c\r\nBcc: x@y.z", to: "d@e.f\nX-Evil: 1", subject: "Hi\r\nBcc: x@y.z", attachments: [],
            date: Self.fixedDate, boundary: "BOUND", messageID: "ID-1")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\r\nBcc:"))
        #expect(!text.contains("\r\nX-Evil:"))
        #expect(text.contains("From: a@b.c Bcc: x@y.z\r\n"))
        #expect(text.contains("Subject: Hi Bcc: x@y.z\r\n"))
    }

    @Test func nearCapBatchBuildsMessageWithinCap() {
        let cap = 20 * 1_048_576
        let items = (0..<30).map { Attachment(filename: "Book \($0) - \(String(repeating: "x", count: 150)).epub", data: Data(count: 1_048_576 - 7)) }
        for batch in Batching.batches(items, maxBytes: cap) {
            let message = MIMEMessage.build(from: "me@icloud.com", to: "kindle@kindle.com", subject: "\(batch.count) books", attachments: batch)
            #expect(message.count <= cap)
        }
        // Packed right up to the limit: one more attachment would not fit.
        let batch = Batching.batches(items, maxBytes: cap)[0]
        #expect(Batching.messageOverhead + batch.count * (Batching.attachmentOverhead + Batching.encodedSize(1_048_576 - 7)) <= cap)
    }
}
