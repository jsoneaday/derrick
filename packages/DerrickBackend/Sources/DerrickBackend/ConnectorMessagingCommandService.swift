import DBRepository
import DBRepository
import Foundation
import ServiceContracts

public enum ConnectorMessagingCommandError: Error, LocalizedError, Sendable {
    case duplicateOperationID
    case operationNotFound
    case invalidRequest(String)
    case connectorUnavailable(String)
    case credentialsMissing

    public var errorDescription: String? {
        switch self {
        case .duplicateOperationID:
            return "A connector operation with this id is already running."
        case .operationNotFound:
            return "Connector operation was not found."
        case .invalidRequest(let detail):
            return detail
        case .connectorUnavailable(let pluginID):
            return "Messaging connector '\(pluginID)' is not available."
        case .credentialsMissing:
            return "Connector credentials are missing."
        }
    }
}

/// Daemon-owned connector bootstrap and send. Runs `plugin.invoke` in-process and persists to SQLite.
public actor ConnectorMessagingCommandService {
    public static let shared = ConnectorMessagingCommandService()

    private struct OperationState {
        var status: ConnectorOperationStatus
        var error: String?
    }

    private var operations: [String: OperationState] = [:]

    private init() {}

    public func submit(
        _ request: ConnectorOperationRequest,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async throws -> ConnectorOperationAckDTO {
        let operationID = request.operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let pluginID = request.pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !operationID.isEmpty, !pluginID.isEmpty else {
            throw ConnectorMessagingCommandError.invalidRequest("operationID and pluginID are required.")
        }
        if operations[operationID] != nil {
            throw ConnectorMessagingCommandError.duplicateOperationID
        }
        operations[operationID] = OperationState(status: .running, error: nil)
        await log(
            level: .info,
            code: "accepted",
            message: "Connector \(request.kind.rawValue) accepted pluginID=\(pluginID) operationID=\(operationID)",
            request: request
        )
        Task {
            await self.run(request, repositoryProvider: repositoryProvider)
        }
        return ConnectorOperationAckDTO(operationID: operationID, accepted: true, message: "ok")
    }

    public func poll(_ request: ConnectorOperationPollRequest) throws -> ConnectorOperationPollResult {
        let operationID = request.operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let state = operations[operationID] else {
            throw ConnectorMessagingCommandError.operationNotFound
        }
        let result = ConnectorOperationPollResult(
            operationID: operationID,
            status: state.status,
            error: state.error
        )
        if state.status != .running {
            operations.removeValue(forKey: operationID)
        }
        return result
    }

    private func run(
        _ request: ConnectorOperationRequest,
        repositoryProvider: @escaping @Sendable () async throws -> DBRepository
    ) async {
        await log(
            level: .info,
            code: "start",
            message: "Connector \(request.kind.rawValue) running pluginID=\(request.pluginID) operationID=\(request.operationID)",
            request: request
        )
        do {
            let repository = try await repositoryProvider()
            guard let adapter = MessagingIngressRegistry.adapter(for: request.pluginID) else {
                throw ConnectorMessagingCommandError.connectorUnavailable(request.pluginID)
            }
            guard adapter.hasCredentials() else {
                throw ConnectorMessagingCommandError.credentialsMissing
            }
            switch request.kind {
            case .bootstrap:
                try await adapter.bootstrap(repository: repository)
            case .send:
                guard let vendorThreadID = request.vendorThreadID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !vendorThreadID.isEmpty,
                      let threadID = request.threadID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !threadID.isEmpty,
                      let text = request.text
                else {
                    throw ConnectorMessagingCommandError.invalidRequest(
                        "send requires vendorThreadID, threadID, and text."
                    )
                }
                try await adapter.sendMessage(
                    vendorThreadID: vendorThreadID,
                    text: text,
                    threadID: threadID,
                    repository: repository
                )
            }
            finish(request.operationID, status: .completed, error: nil)
            await log(
                level: .info,
                code: "completed",
                message: "Connector \(request.kind.rawValue) completed pluginID=\(request.pluginID) operationID=\(request.operationID)",
                request: request
            )
            DerrickMessagingInboundSignal.postRefresh()
        } catch {
            finish(request.operationID, status: .failed, error: error.localizedDescription)
            await log(
                level: .error,
                code: "failed",
                message: "Connector \(request.kind.rawValue) failed pluginID=\(request.pluginID): \(error.localizedDescription)",
                request: request,
                extra: ["error": error.localizedDescription]
            )
            DerrickMessagingInboundSignal.postRefresh()
        }
    }

    private func log(
        level: ServiceLogLevel,
        code: String,
        message: String,
        request: ConnectorOperationRequest,
        extra: [String: String] = [:]
    ) async {
        var payload: [String: String] = [
            "operationID": request.operationID,
            "pluginID": request.pluginID,
            "kind": request.kind.rawValue,
            "process": "daemon"
        ]
        if let vendorThreadID = request.vendorThreadID {
            payload["vendorThreadID"] = vendorThreadID
        }
        if let threadID = request.threadID {
            payload["threadID"] = threadID
        }
        if let text = request.text {
            payload["textLength"] = "\(text.count)"
            payload["textPreview"] = String(text.prefix(120))
        }
        for (key, value) in extra {
            payload[key] = value
        }
        let detailJSON = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) }
        await ServiceLogRecorder.shared.record(
            service: "connector",
            level: level,
            code: code,
            message: message,
            detailJSON: detailJSON
        )
    }

    private func finish(_ operationID: String, status: ConnectorOperationStatus, error: String?) {
        operations[operationID] = OperationState(status: status, error: error)
    }
}
