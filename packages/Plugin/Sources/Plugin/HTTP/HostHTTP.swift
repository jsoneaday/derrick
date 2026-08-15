import Foundation

public struct HostHTTPRequest: Codable, Sendable, Hashable {
    public var requestID: String
    public var method: String
    public var url: String
    public var authRef: String?
    public var headers: [String: String]
    public var json: Data?
    public var maxBytes: Int

    public init(
        requestID: String,
        method: String,
        url: String,
        authRef: String? = nil,
        headers: [String: String] = [:],
        json: Data? = nil,
        maxBytes: Int = 1_048_576
    ) {
        self.requestID = requestID
        self.method = method.uppercased()
        self.url = url
        self.authRef = authRef
        self.headers = PluginSSRFPolicy.stripRequestHeaders(headers)
        self.json = json
        self.maxBytes = maxBytes
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case method, url
        case authRef = "auth_ref"
        case headers, json
        case maxBytes = "max_bytes"
    }
}

public struct HostHTTPResponse: Codable, Sendable, Hashable {
    public var requestID: String
    public var status: Int
    public var headers: [String: String]
    /// Guest-facing payload. UTF-8 text (HTML, JSON, or plain). Never `Data` — JSONEncoder would base64 it.
    public var body: String
    public var json: Data?
    public var fileHandle: String?
    public var error: String?

    public init(
        requestID: String,
        status: Int,
        headers: [String: String] = [:],
        body: String = "",
        json: Data? = nil,
        fileHandle: String? = nil,
        error: String? = nil
    ) {
        self.requestID = requestID
        self.status = status
        self.headers = PluginSSRFPolicy.stripResponseHeaders(headers)
        self.body = body
        self.json = json
        self.fileHandle = fileHandle
        self.error = error
    }

    /// `error` nil / blank is success. HTTP status is separate.
    public var succeeded: Bool { !PluginFailureSemantics.isFailure(error) }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case status, headers, body, json
        case fileHandle = "file_handle"
        case error
    }
}
