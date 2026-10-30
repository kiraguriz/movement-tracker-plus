import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    /// Header names as given; the transport sends them as is.
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 30) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Header names lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }
}

/// A response whose body is still arriving: the status and headers now, the bytes as chunks of any size.
public struct HTTPStreamResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, any Error>

    public init(status: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, any Error>) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }
}

/// What the client needs from the network. The real one wraps URLSession; tests inject a scripted one.
/// Failures to connect or finish are thrown as `URLError`s; cancelling the calling task cancels the request.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func openStream(_ request: HTTPRequest) async throws -> HTTPStreamResponse
}

/// URLSession-backed transport. Uses an ephemeral session (no cookies, no disk cache) unless one is given.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: configuration)
        }
    }

    private func urlRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { result[key] = value }
        }
        return result
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: urlRequest(request))
        guard let http = response as? HTTPURLResponse else { throw CoachError.malformedResponse("Not an HTTP response") }
        return HTTPResponse(status: http.statusCode, headers: Self.headers(of: http), body: data)
    }

    public func openStream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let (bytes, response) = try await session.bytes(for: urlRequest(request))
        guard let http = response as? HTTPURLResponse else { throw CoachError.malformedResponse("Not an HTTP response") }
        // AsyncBytes yields single bytes; hand them on a line at a time so consumers see whole events quickly
        // without paying an async hop per byte. A chunk boundary may fall inside a multi-byte character; the
        // SSE parser reassembles bytes before decoding.
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A || chunk.count >= 4096 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(status: http.statusCode, headers: Self.headers(of: http), body: body)
    }
}
