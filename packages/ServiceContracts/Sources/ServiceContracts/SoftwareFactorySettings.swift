import Foundation

/// Settings flag. Off by default (including Release).
public struct SoftwareFactorySettings: Codable, Sendable, Equatable, Hashable {
    public static let configKey = "softwareFactory.enabled.v1"

    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public static let `default` = SoftwareFactorySettings(enabled: false)
}