import Foundation

/// Versioned messages crossing the Docker guest / Swift host boundary.
public enum PluginRuntimeProtocol {
    public static let currentVersion = 1
}

public enum PluginRuntimeMessageKind: String, Codable, Sendable, Hashable {
    case request
    case result
}

public enum PluginRuntimeOperation: String, Codable, Sendable, Hashable {
    case httpRequest = "http.request"
    case uiRequest = "ui.request"
    case secretRequest = "secret.request"
    case storageRead = "storage.read"
    case storageWrite = "storage.write"
    case scheduleCreate = "schedule.create"
    case resultEmit = "result.emit"
}

public struct PluginRuntimeRequest: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var messageKind: PluginRuntimeMessageKind
    public var requestID: String
    public var sequence: Int
    public var operation: PluginRuntimeOperation
    public var payload: PluginJSON

    public init(
        protocolVersion: Int = PluginRuntimeProtocol.currentVersion,
        requestID: String,
        sequence: Int,
        operation: PluginRuntimeOperation,
        payload: PluginJSON
    ) {
        self.protocolVersion = protocolVersion
        self.messageKind = .request
        self.requestID = requestID
        self.sequence = sequence
        self.operation = operation
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case messageKind = "message_kind"
        case requestID = "request_id"
        case sequence
        case operation
        case payload
    }

    public init(
        envelope: PluginEnvelope,
        sequence: Int,
        requestID: String = UUID().uuidString
    ) throws {
        guard let operation = Self.operation(for: envelope.verb) else {
            throw PluginRuntimeProtocolError.operationNotAllowed(
                .resultEmit
            )
        }
        self.init(
            requestID: requestID,
            sequence: sequence,
            operation: operation,
            payload: .object(envelope.payload)
        )
    }

    public init(
        sequence: Int,
        payload: PluginHTTPFetchRequest
    ) throws {
        try self.init(
            requestID: payload.requestID,
            sequence: sequence,
            operation: .httpRequest,
            payload: Self.jsonValue(payload)
        )
    }

    public init(
        sequence: Int,
        payload: PluginUIRequest
    ) throws {
        try self.init(
            requestID: payload.requestID,
            sequence: sequence,
            operation: .uiRequest,
            payload: Self.jsonValue(payload)
        )
    }

    public init(
        sequence: Int,
        payload: PluginSecretRequest
    ) throws {
        try self.init(
            requestID: payload.requestID,
            sequence: sequence,
            operation: .secretRequest,
            payload: Self.jsonValue(payload)
        )
    }

    public init(
        sequence: Int,
        payload: PluginStorageReadRequest
    ) throws {
        try self.init(
            requestID: payload.requestID,
            sequence: sequence,
            operation: .storageRead,
            payload: Self.jsonValue(payload)
        )
    }

    public init(
        sequence: Int,
        payload: PluginStorageWriteRequest
    ) throws {
        try self.init(
            requestID: payload.requestID,
            sequence: sequence,
            operation: .storageWrite,
            payload: Self.jsonValue(payload)
        )
    }

    public init(
        sequence: Int,
        payload: PluginScheduleRequest
    ) throws {
        try self.init(
            requestID: payload.requestID,
            sequence: sequence,
            operation: .scheduleCreate,
            payload: Self.jsonValue(payload)
        )
    }

    public var typedPayload: PluginRuntimeTypedPayload? {
        switch operation {
        case .httpRequest:
            return decode(PluginHTTPFetchRequest.self).map { .http($0) }
        case .uiRequest:
            return decode(PluginUIRequest.self).map { .ui($0) }
        case .secretRequest:
            return decode(PluginSecretRequest.self).map { .secret($0) }
        case .storageRead:
            return decode(PluginStorageReadRequest.self).map { .storageRead($0) }
        case .storageWrite:
            return decode(PluginStorageWriteRequest.self).map { .storageWrite($0) }
        case .scheduleCreate:
            return decode(PluginScheduleRequest.self).map { .schedule($0) }
        case .resultEmit:
            return nil
        }
    }

    private static func operation(for verb: PluginVerb) -> PluginRuntimeOperation? {
        switch verb {
        case .httpRequest:
            return .httpRequest
        case .resultEmit:
            return .resultEmit
        case .uiPresent:
            return .uiRequest
        case .secretRequest:
            return .secretRequest
        case .storageRead:
            return .storageRead
        case .storageWrite:
            return .storageWrite
        case .jobSchedule:
            return .scheduleCreate
        case .messagePost, .log:
            return nil
        }
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> PluginJSON {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(PluginJSON.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

public enum PluginRuntimeTypedPayload: Sendable, Hashable {
    case http(PluginHTTPFetchRequest)
    case ui(PluginUIRequest)
    case secret(PluginSecretRequest)
    case storageRead(PluginStorageReadRequest)
    case storageWrite(PluginStorageWriteRequest)
    case schedule(PluginScheduleRequest)
}

public struct PluginRuntimeResult: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var messageKind: PluginRuntimeMessageKind
    public var requestID: String
    public var sequence: Int
    public var ok: Bool
    public var payload: PluginJSON?
    public var error: PluginRuntimeError?

    public init(
        protocolVersion: Int = PluginRuntimeProtocol.currentVersion,
        requestID: String,
        sequence: Int,
        ok: Bool,
        payload: PluginJSON? = nil,
        error: PluginRuntimeError? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.messageKind = .result
        self.requestID = requestID
        self.sequence = sequence
        self.ok = ok
        self.payload = payload
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case messageKind = "message_kind"
        case requestID = "request_id"
        case sequence
        case ok
        case payload
        case error
    }

    public func decodedPayload<T: Decodable>(_ type: T.Type) -> T? {
        guard let payload,
              let data = try? JSONEncoder().encode(payload) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}

public struct PluginRuntimeError: Codable, Sendable, Hashable {
    public var code: String
    public var message: String
    public var retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public enum PluginRuntimeProtocolError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedVersion(Int)
    case wrongMessageKind
    case emptyRequestID
    case invalidSequence
    case capabilityDenied(PluginCapability)
    case operationNotAllowed(PluginRuntimeOperation)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported plugin runtime protocol version: \(version)."
        case .wrongMessageKind:
            return "The runtime message has the wrong message kind."
        case .emptyRequestID:
            return "Runtime request_id must not be empty."
        case .invalidSequence:
            return "Runtime sequence must not be negative."
        case .capabilityDenied(let capability):
            return "Plugin capability denied: \(capability.rawValue)."
        case .operationNotAllowed(let operation):
            return "Runtime operation is not allowed: \(operation.rawValue)."
        }
    }
}

public enum PluginRuntimeProtocolValidator {
    public static func validate(
        _ request: PluginRuntimeRequest,
        against spec: PluginSpec,
        previousSequence: Int? = nil
    ) throws {
        guard request.protocolVersion == PluginRuntimeProtocol.currentVersion else {
            throw PluginRuntimeProtocolError.unsupportedVersion(request.protocolVersion)
        }
        guard request.messageKind == .request else {
            throw PluginRuntimeProtocolError.wrongMessageKind
        }
        guard !request.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginRuntimeProtocolError.emptyRequestID
        }
        guard request.sequence >= 0,
              previousSequence.map({ request.sequence > $0 }) ?? true else {
            throw PluginRuntimeProtocolError.invalidSequence
        }

        let capability: PluginCapability
        switch request.operation {
        case .httpRequest:
            capability = .httpFetch
        case .uiRequest:
            capability = .uiRequest
        case .secretRequest:
            capability = .secretRequest
        case .storageRead, .storageWrite:
            capability = .storage
        case .scheduleCreate:
            capability = .scheduling
        case .resultEmit:
            capability = .resultEmit
        }
        guard spec.capabilities.contains(capability) else {
            throw PluginRuntimeProtocolError.capabilityDenied(capability)
        }
        guard request.sequence < spec.limits.maxHops else {
            throw PluginRuntimeProtocolError.operationNotAllowed(request.operation)
        }
    }
}
