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

    public static func decodeValidated(_ data: Data) throws -> PluginHopEvent {
        try GuestContractValidation.validateHopEventJSON(data)
        return try JSONDecoder().decode(PluginHopEvent.self, from: data)
    }

    public func encodeValidated() throws -> Data {
        let data = try JSONEncoder().encode(self)
        try GuestContractValidation.validateHopEventJSON(data)
        return data
    }

    /// Live hops keep earlier HTTP bodies so pagination can see previous pages.
    /// The same `request_id` on a later hop replaces the earlier row.
    public func mergingLatestHTTPResults(_ latest: PluginHopEvent) -> PluginHopEvent {
        var byID: [String: HostHTTPResponse] = [:]
        var anonymous: [HostHTTPResponse] = []
        func ingest(_ rows: [HostHTTPResponse]) {
            for row in rows {
                let id = row.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
                if id.isEmpty {
                    anonymous.append(row)
                } else {
                    byID[id] = row
                }
            }
        }
        ingest(httpResults ?? [])
        ingest(latest.httpResults ?? [])
        let merged = byID.keys.sorted().compactMap { byID[$0] } + anonymous
        return PluginHopEvent(
            kind: .httpResults,
            httpResults: merged,
            params: latest.params ?? params
        )
    }
}
