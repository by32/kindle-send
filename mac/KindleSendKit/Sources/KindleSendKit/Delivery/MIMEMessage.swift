import Foundation

public struct Attachment: Sendable {
    public var filename: String
    public var data: Data
    /// e.g. "application/epub+zip".
    public var mimeType: String

    public init(filename: String, data: Data, mimeType: String = "application/epub+zip") {
        self.filename = filename
        self.data = data
        self.mimeType = mimeType
    }
}

public enum MIMEMessage {
    /// A complete RFC 5322 message with CRLF line endings. Not dot-stuffed; the SMTP client does that.
    public static func build(
        from: String, to: String, subject: String, attachments: [Attachment],
        date: Date = .now, boundary: String = UUID().uuidString,
        messageID: String = UUID().uuidString
    ) -> Data {
        var lines = [
            "From: \(headerValue(from))",
            "To: \(headerValue(to))",
            "Subject: \(encodedSubject(subject))",
            "Date: \(rfc5322Date(date))",
            "Message-ID: <\(headerValue(messageID))@kindlesend.local>",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
            "",
        ]
        for attachment in attachments {
            lines += [
                "--\(boundary)",
                "Content-Type: \(attachment.mimeType); \(nameParameter(attachment.filename))",
                "Content-Transfer-Encoding: base64",
                "Content-Disposition: attachment; \(filenameParameters(attachment.filename))",
                "",
                body(attachment.data),
            ]
        }
        lines += ["--\(boundary)--", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    // MARK: - Headers

    /// Header values must stay on one line.
    private static func headerValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// RFC 2047 `=?UTF-8?B?…?=` when non-ASCII, split into words that stay under 75 characters.
    static func encodedSubject(_ subject: String) -> String {
        let value = headerValue(subject)
        guard !value.allSatisfy(\.isASCII) else { return value }
        var words: [String] = []
        var chunk = Data()
        func flush() {
            if !chunk.isEmpty { words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=") }
            chunk = Data()
        }
        for character in value {
            let bytes = Data(String(character).utf8)
            if chunk.count + bytes.count > 36 { flush() }
            chunk.append(bytes)
        }
        flush()
        return words.joined(separator: "\r\n ")
    }

    // MARK: - Attachment parts

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func asciiFallback(_ filename: String) -> String {
        String(filename.map { $0.isASCII && !$0.isNewline ? $0 : "_" })
    }

    private static func nameParameter(_ filename: String) -> String {
        "name=\(quoted(asciiFallback(filename)))"
    }

    private static func filenameParameters(_ filename: String) -> String {
        guard !filename.allSatisfy(\.isASCII) else { return "filename=\(quoted(filename))" }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "!#$&+-.^_`|~")
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "filename=\(quoted(asciiFallback(filename))); filename*=UTF-8''\(encoded)"
    }

    /// Base64 in 76-character lines, CRLF-terminated.
    private static func body(_ data: Data) -> String {
        let options: Data.Base64EncodingOptions = [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
        return data.base64EncodedString(options: options)
    }
}
