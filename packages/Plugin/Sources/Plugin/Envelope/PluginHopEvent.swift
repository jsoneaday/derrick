import Foundation

/// Host → guest invoke. Encoded with JSONEncoder so optional `error` is omitted / null, never a crash.
public struct PluginHostInvoke: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var verb: String
    public var seq: Int
    public var event: PluginHopEvent

    public init(seq: Int, event: PluginHopEvent) {
        self.schemaVersion = PluginContract.envelopeSchemaVersion
        self.verb = "invoke"
        self.seq = seq
        self.event = event
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case verb, seq, event
    }
}

public struct PluginHopEvent: Codable, Sendable, Hashable {
    public var kind: PluginEventKind
    public var httpResults: [HostHTTPResponse]?
    /// Caller-supplied JSON for this invoke. Survives hops. Not secrets.
    public var params: [String: PluginJSON]?

    public init(
        kind: PluginEventKind,
        httpResults: [HostHTTPResponse]? = nil,
        params: [String: PluginJSON]? = nil
    ) {
        self.kind = kind
        self.httpResults = httpResults
        self.params = params
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case httpResults = "http_results"
        case params
    }
}
