import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct GoogleHTTPClient: HTTPClient {
    private let allowControl: Bool
    public init(allowControl: Bool = false) { self.allowControl = allowControl }

    // A positive allowlist of methods AND paths. No thermostat write endpoint.
    public static func permits(_ request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme == "https", url.user == nil,
              url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return false }
        if request.httpMethod == "POST", url.host == "oauth2.googleapis.com", url.path == "/token" {
            return true
        }
        guard request.httpMethod == "GET", url.host == "smartdevicemanagement.googleapis.com" else { return false }
        let parts = url.path.split(separator: "/")
        return parts.count == 4 && parts[0] == "v1" && parts[1] == "enterprises"
            && UUID(uuidString: String(parts[2])) != nil && parts[3] == "devices"
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard Self.permits(request) || (allowControl && NestCommand.permits(request)) else { throw ReaderError.invalidConfiguration }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirect())
            guard let http = response as? HTTPURLResponse else { throw ReaderError.malformedResponse }
            guard response.expectedContentLength <= 1_048_576 else { throw ReaderError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1_048_576 else { throw ReaderError.responseTooLarge }
                data.append(byte)
            }
            return HTTPResponse(status: http.statusCode, body: data)
        } catch let error as ReaderError { throw error }
        catch { throw ReaderError.network }
    }
}
