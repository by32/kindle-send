import Foundation

public protocol HTTPClient: Sendable {
    func data(from url: URL) async throws -> (Data, HTTPURLResponse)
}

public enum HTTPError: Error, Equatable, LocalizedError {
    /// A response outside 200...299.
    case status(Int, URL)
    case notHTTP(URL)

    public var errorDescription: String? {
        switch self {
        case let .status(code, url): "HTTP \(code) from \(url.absoluteString)"
        case let .notHTTP(url): "Not an HTTP response from \(url.absoluteString)"
        }
    }
}

/// Sends every request with the app's User-Agent and a 60 s timeout; throws `HTTPError` on non-2xx.
public struct URLSessionHTTPClient: HTTPClient {
    static let userAgent = "KindleSend/1.0 (+https://github.com/by32/kindle-send)"
    static let timeout: TimeInterval = 60

    public init() {}

    public func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: Self.request(for: url))
        return (data, try Self.validate(response, for: url))
    }

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func validate(_ response: URLResponse, for url: URL) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw HTTPError.notHTTP(url) }
        guard (200...299).contains(http.statusCode) else { throw HTTPError.status(http.statusCode, url) }
        return http
    }
}
