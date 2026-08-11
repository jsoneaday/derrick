import Foundation

/// User-editable container lifecycle settings (persisted in app config).
public struct ContainerLifecycleSettings: Codable, Sendable, Equatable {
    public var containerRunMaxTTLSeconds: Int

    public init(containerRunMaxTTLSeconds: Int) {
        self.containerRunMaxTTLSeconds = containerRunMaxTTLSeconds
    }

    public static let `default` = ContainerLifecycleSettings(
        containerRunMaxTTLSeconds: ContainerLifecyclePolicy.derrickDefault.containerRunMaxTTLSeconds
    )

    public static let minimumTTLSeconds = 60
    public static let maximumTTLSeconds = 60 * 60

    public func clamped() -> ContainerLifecycleSettings {
        ContainerLifecycleSettings(
            containerRunMaxTTLSeconds: Self.clamp(
                containerRunMaxTTLSeconds,
                min: Self.minimumTTLSeconds,
                max: Self.maximumTTLSeconds
            )
        )
    }

    public var containerRunMaxTTLMinutes: Int {
        max(1, (containerRunMaxTTLSeconds + 59) / 60)
    }

    public static func fromMinutes(_ minutes: Int) -> ContainerLifecycleSettings {
        ContainerLifecycleSettings(containerRunMaxTTLSeconds: minutes * 60).clamped()
    }

    private static func clamp(_ value: Int, min: Int, max: Int) -> Int {
        Swift.min(Swift.max(value, min), max)
    }
}

/// Process-wide container lease TTL read by Docker runners (updated when Settings change).
public enum ContainerLifecycleRuntime: Sendable {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var settings = ContainerLifecycleSettings.default
    }

    private static let storage = Storage()

    public static var current: ContainerLifecycleSettings {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.settings
    }

    public static var containerRunMaxTTLSeconds: Int {
        current.containerRunMaxTTLSeconds
    }

    public static func apply(_ newSettings: ContainerLifecycleSettings) {
        storage.lock.lock()
        storage.settings = newSettings.clamped()
        storage.lock.unlock()
    }

    /// Test-only reset.
    public static func resetToDefaultForTesting() {
        apply(.default)
    }
}
