import Foundation

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
