import Foundation

/// Guest `http.request` envelope as a native host type.
/// Codable keys are exactly the envelope-list `http.request` fields.
public struct HostHTTPRequest: Codable, Sendable, Hashable {
    public static let maxResponseBytes = 1_048_576

    public var requestID: String
    public var method: String
    public var url: String
    public var authRef: String?
    public var headers: [String: String]
    public var json: PluginJSON?

    public init(
        requestID: String,
        method: String,
        url: String,
        authRef: String? = nil,
        headers: [String: String] = [:],
        json: PluginJSON? = nil
    ) {
        self.requestID = requestID
        self.method = method.uppercased()
        self.url = url
        self.authRef = authRef
        self.headers = PluginSSRFPolicy.stripRequestHeaders(headers)
        self.json = json
    }

    /// Deserialize a validated guest `http.request` envelope.
    public init(envelope: PluginEnvelope) throws {
        guard envelope.verb == .httpRequest else {
            throw HostHTTPRequestError.notAnHTTPRequest
        }
        let data = try JSONEncoder().encode(PluginJSON.object(envelope.payload))
        self = try JSONDecoder().decode(HostHTTPRequest.self, from: data)
    }

    public static func all(in envelopes: [PluginEnvelope]) throws -> [HostHTTPRequest] {
        try envelopes.compactMap { envelope in
            guard envelope.verb == .httpRequest else { return nil }
            return try HostHTTPRequest(envelope: envelope)
        }
    }

    /// Bytes the host puts on the wire from schema field `json`.
    public var httpBody: Data? {
        guard let json else { return nil }
        switch json {
        case .null:
            return nil
        case .string(let value):
            return value.data(using: .utf8)
        case .bool, .number, .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try? encoder.encode(json)
        }
    }

    public var wireHeaders: [String: String] {
        var headers = self.headers
        let hasContentType = headers.keys.contains {
            $0.caseInsensitiveCompare("Content-Type") == .orderedSame
        }
        if !hasContentType, usesStructuredJSONBody {
            headers["Content-Type"] = "application/json"
        }
        return headers
    }

    private var usesStructuredJSONBody: Bool {
        switch json {
        case .object, .array:
            return true
        default:
            return false
        }
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case method, url
        case authRef = "auth_ref"
        case headers, json
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
            ?? UUID().uuidString
        method = (try container.decodeIfPresent(String.self, forKey: .method) ?? "GET")
            .uppercased()
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        authRef = try container.decodeIfPresent(String.self, forKey: .authRef)
        headers = PluginSSRFPolicy.stripRequestHeaders(
            try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        )
        json = try container.decodeIfPresent(PluginJSON.self, forKey: .json)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(method, forKey: .method)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(authRef, forKey: .authRef)
        try container.encode(headers, forKey: .headers)
        try container.encodeIfPresent(json, forKey: .json)
    }
}

public enum HostHTTPRequestError: Error, Equatable, LocalizedError, Sendable {
    case notAnHTTPRequest

    public var errorDescription: String? {
        switch self {
        case .notAnHTTPRequest:
            return "Envelope is not an http.request."
        }
    }
}

/// Guest stdin `http_results` row. Codable keys are exactly hop-event.schema.json items.
public struct HostHTTPResponse: Codable, Sendable, Hashable {
    public var requestID: String
    public var status: Int
    public var headers: [String: String]
    /// Guest-facing payload. UTF-8 text (HTML, JSON, or plain). Never `Data` — JSONEncoder would base64 it.
    public var body: String
    public var error: String?

    public init(
        requestID: String,
        status: Int,
        headers: [String: String] = [:],
        body: String = "",
        error: String? = nil
    ) {
        self.requestID = requestID
        self.status = status
        self.headers = PluginSSRFPolicy.stripResponseHeaders(headers)
        self.body = body
        self.error = error
    }

    /// `error` nil / blank is success. HTTP status is separate.
    public var succeeded: Bool { !PluginFailureSemantics.isFailure(error) }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case status, headers, body, error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(status, forKey: .status)
        try container.encode(headers, forKey: .headers)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(error, forKey: .error)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        status = try container.decode(Int.self, forKey: .status)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}
