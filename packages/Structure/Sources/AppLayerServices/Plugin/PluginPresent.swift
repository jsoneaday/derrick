import Foundation

/// Host pipe that draws a Return payload inside a Chat tab.
/// Not a Work verb and not a product SKU. The human does not pick this unless the host cannot decide.
public enum PluginPresent: String, Sendable, Hashable, Codable, CaseIterable {
    case conversation
    case thread
    case generatedView
    case file
    case image
}

public enum PluginPresentSource: String, Sendable, Hashable, Codable {
    case inferred
    case asked
    case wrongnessOverride
}

public enum PluginPresentBinding: Equatable, Sendable {
    case decided(PluginPresent)
    case needsHumanChoice
}
