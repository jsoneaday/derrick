import Foundation

/// Validated host library tree from a guest `ui.present` envelope.
public struct PluginUIPresentRequest: Codable, Sendable, Hashable {
    public var root: HostUINode

    public init(root: HostUINode) {
        self.root = root
    }
}

public struct PluginSecretRequest: Codable, Sendable, Hashable {
    public var requestID: String
    public var secretRef: String
    public var reason: String

    public init(requestID: String, secretRef: String, reason: String) {
        self.requestID = requestID
        self.secretRef = secretRef
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case secretRef = "secret_ref"
        case reason
    }
}

/// Secret values never cross into generated code. The result only reports availability.
public struct PluginSecretResult: Codable, Sendable, Hashable {
    public var requestID: String
    public var available: Bool
    public var error: PluginRuntimeError?

    public init(requestID: String, available: Bool, error: PluginRuntimeError? = nil) {
        self.requestID = requestID
        self.available = available
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case available, error
    }
}

public struct PluginStorageReadRequest: Codable, Sendable, Hashable {
    public var requestID: String
    public var key: String

    public init(requestID: String, key: String) {
        self.requestID = requestID
        self.key = key
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case key
    }
}

public struct PluginStorageWriteRequest: Codable, Sendable, Hashable {
    public var requestID: String
    public var key: String
    public var value: PluginJSON

    public init(requestID: String, key: String, value: PluginJSON) {
        self.requestID = requestID
        self.key = key
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case key, value
    }
}

public struct PluginStorageResult: Codable, Sendable, Hashable {
    public var requestID: String
    public var found: Bool
    public var value: PluginJSON?
    public var error: PluginRuntimeError?

    public init(
        requestID: String,
        found: Bool,
        value: PluginJSON? = nil,
        error: PluginRuntimeError? = nil
    ) {
        self.requestID = requestID
        self.found = found
        self.value = value
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case found, value, error
    }
}

public struct PluginScheduleRequest: Codable, Sendable, Hashable {
    public var requestID: String
    public var intervalSeconds: Int
    public var timezone: String

    public init(requestID: String, intervalSeconds: Int, timezone: String) {
        self.requestID = requestID
        self.intervalSeconds = intervalSeconds
        self.timezone = timezone
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case intervalSeconds = "interval_seconds"
        case timezone
    }
}

public struct PluginScheduleResult: Codable, Sendable, Hashable {
    public var requestID: String
    public var scheduleID: String?
    public var created: Bool
    public var error: PluginRuntimeError?

    public init(
        requestID: String,
        scheduleID: String? = nil,
        created: Bool,
        error: PluginRuntimeError? = nil
    ) {
        self.requestID = requestID
        self.scheduleID = scheduleID
        self.created = created
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case scheduleID = "schedule_id"
        case created, error
    }
}
