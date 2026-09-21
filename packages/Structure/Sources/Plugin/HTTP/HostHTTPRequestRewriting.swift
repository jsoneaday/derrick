import Foundation

/// Bytes the host actually puts on the wire after optional vendor rewriting.
public struct HostHTTPWireRequest: Equatable, Sendable {
    public var url: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: String, headers: [String: String], body: Data?) {
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// Vendor-specific HTTP shape (form vs JSON, query flags). Structure stays vendor-neutral.
public protocol HostHTTPRequestRewriting: Sendable {
    func rewritten(_ request: HostHTTPRequest) -> HostHTTPWireRequest
}

public struct PassthroughHTTPRequestRewriter: HostHTTPRequestRewriting {
    public init() {}

    public func rewritten(_ request: HostHTTPRequest) -> HostHTTPWireRequest {
        HostHTTPWireRequest(
            url: request.url,
            headers: request.wireHeaders,
            body: request.httpBody
        )
    }
}
