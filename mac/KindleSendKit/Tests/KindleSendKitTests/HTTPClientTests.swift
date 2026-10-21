import Foundation
import Testing
@testable import KindleSendKit

@Suite struct HTTPClientTests {
    private let url = URL(string: "https://standardebooks.org/ebooks?page=1")!

    @Test func requestIdentifiesAppAndTimesOut() {
        let request = URLSessionHTTPClient.request(for: url)
        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "KindleSend/1.0 (+https://github.com/by32/kindle-send)")
        #expect(request.timeoutInterval == 60)
    }

    @Test func acceptsSuccess() throws {
        for status in [200, 204, 299] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            #expect(try URLSessionHTTPClient.validate(response, for: url) === response)
        }
    }

    @Test func rejectsNon2xxWithStatusAndURL() {
        for status in [199, 301, 403, 404, 500] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            #expect(throws: HTTPError.status(status, url)) { try URLSessionHTTPClient.validate(response, for: url) }
        }
        let message = HTTPError.status(403, url).localizedDescription
        #expect(message.contains("403") && message.contains(url.absoluteString))
    }

    @Test func rejectsNonHTTPResponse() {
        let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        #expect(throws: HTTPError.notHTTP(url)) { try URLSessionHTTPClient.validate(response, for: url) }
    }
}
