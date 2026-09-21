import Foundation

/// Latest factory manifest row for a compiled plugin. Values are JSON text, not binaries.
public struct PluginFactoryManifestRecord: Sendable, Hashable {
    public let pluginID: String
    public let version: String
    public let manifestJSON: String
    public let reviewSummary: String

    public init(pluginID: String, version: String, manifestJSON: String, reviewSummary: String) {
        self.pluginID = pluginID
        self.version = version
        self.manifestJSON = manifestJSON
        self.reviewSummary = reviewSummary
    }
}

/// Read path for factory manifests. UI and AppLayer take this protocol, not SQLite.
public protocol PluginFactoryManifestCatalog: Actor {
    func listLatestPluginFactoryManifests() throws -> [PluginFactoryManifestRecord]
}
