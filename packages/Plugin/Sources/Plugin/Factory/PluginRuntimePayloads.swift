import Foundation

public enum PluginHTTPMethod: String, Codable, Sendable, Hashable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
}

public struct PluginHTTPFetchRequest: Codable, Sendable, Hashable {
    public var requestID: String
    public var method: PluginHTTPMethod
    public var url: String
    public var headers: [String: String]
    public var body: PluginJSON?
    public var authRef: String?

    public init(
        requestID: String,
        method: PluginHTTPMethod = .get,
        url: String,
        headers: [String: String] = [:],
        body: PluginJSON? = nil,
        authRef: String? = nil
    ) {
        self.requestID = requestID
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.authRef = authRef
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case method, url, headers, body
        case authRef = "auth_ref"
    }
}

public struct PluginHTTPFetchResponse: Codable, Sendable, Hashable {
    public var requestID: String
    public var status: Int?
    public var headers: [String: String]
    public var body: String?
    public var error: PluginRuntimeError?

    public init(
        requestID: String,
        status: Int? = nil,
        headers: [String: String] = [:],
        body: String? = nil,
        error: PluginRuntimeError? = nil
    ) {
        self.requestID = requestID
        self.status = status
        self.headers = headers
        self.body = body
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case status, headers, body, error
    }
}

public struct PluginUIRequest: Codable, Sendable, Hashable {
    public var requestID: String
    public var title: String
    public var message: String
    public var widgets: [PluginRuntimeUIWidget]

    public init(
        requestID: String,
        title: String,
        message: String = "",
        widgets: [PluginRuntimeUIWidget] = []
    ) {
        self.requestID = requestID
        self.title = title
        self.message = message
        self.widgets = widgets
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case title, message, widgets
    }
}

public struct PluginRuntimeUIWidget: Codable, Sendable, Hashable {
    public var id: String
    public var kind: String
    public var label: String
    public var options: [String]

    public init(
        id: String,
        kind: String,
        label: String,
        options: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.options = options
    }
}

public struct PluginUIAction: Codable, Sendable, Hashable {
    public var requestID: String
    public var widgetID: String
    public var value: PluginJSON?

    public init(requestID: String, widgetID: String, value: PluginJSON? = nil) {
        self.requestID = requestID
        self.widgetID = widgetID
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case widgetID = "widget_id"
        case value
    }
}

public struct PluginUIResult: Codable, Sendable, Hashable {
    public var requestID: String
    public var action: PluginUIAction?
    public var cancelled: Bool
    public var error: PluginRuntimeError?

    public init(
        requestID: String,
        action: PluginUIAction? = nil,
        cancelled: Bool = false,
        error: PluginRuntimeError? = nil
    ) {
        self.requestID = requestID
        self.action = action
        self.cancelled = cancelled
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case action, cancelled, error
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
