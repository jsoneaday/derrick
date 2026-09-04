import Foundation

public enum ExecutionContextDelivery: String, Codable, Sendable, Hashable, CaseIterable {
    case liveChat = "live_chat"
    case notification
    case silent
}

public enum ExecutionContextCapability: String, Codable, Sendable, Hashable, CaseIterable {
    case syncWebCrawl = "sync_web_crawl"
    case hostReviewRetry = "host_review_retry"
}

public enum WorkflowKind: String, Codable, Sendable, Hashable, CaseIterable {
    case pluginFactoryCreate = "plugin_factory_create"
    case pluginFactoryEdit = "plugin_factory_edit"
    case jobStep = "job_step"
    case interactiveTool = "interactive_tool"
    case none
}

public struct WorkflowContextWire: Codable, Sendable, Hashable {
    public let workflowID: String?
    public let kind: WorkflowKind
    public let stepID: String?
    public let stepKind: String?

    public init(
        workflowID: String? = nil,
        kind: WorkflowKind = .none,
        stepID: String? = nil,
        stepKind: String? = nil
    ) {
        self.workflowID = workflowID
        self.kind = kind
        self.stepID = stepID
        self.stepKind = stepKind
    }

    enum CodingKeys: String, CodingKey {
        case workflowID = "workflow_id"
        case kind
        case stepID = "step_id"
        case stepKind = "step_kind"
    }
}

/// Signed cross-boundary execution context (replaces process-local turn flags).
public struct ExecutionContextWire: Codable, Sendable, Hashable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let sessionID: String
    public let turnID: String?
    public let agentID: String?
    /// `ServicePrincipal.logLabel` wire form.
    public let principal: String
    public let workflow: WorkflowContextWire?
    public let delivery: ExecutionContextDelivery
    public let capabilities: [ExecutionContextCapability]

    public init(
        sessionID: String,
        principal: ServicePrincipal,
        turnID: String? = nil,
        agentID: String? = nil,
        workflow: WorkflowContextWire? = nil,
        delivery: ExecutionContextDelivery = .liveChat,
        capabilities: [ExecutionContextCapability] = []
    ) {
        self.schemaVersion = Self.schemaVersion
        self.sessionID = sessionID
        self.turnID = turnID
        self.agentID = agentID
        self.principal = principal.logLabel
        self.workflow = workflow
        self.delivery = delivery
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case agentID = "agent_id"
        case principal
        case workflow
        case delivery
        case capabilities
    }

    public func encodedJSON() throws -> String {
        let data = try JSONEncoder.service.encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ExecutionContextWireError.encodingFailed
        }
        return text
    }

    public static func decodeJSON(_ text: String) throws -> ExecutionContextWire {
        guard let data = text.data(using: .utf8) else {
            throw ExecutionContextWireError.invalidJSON
        }
        return try JSONDecoder.service.decode(ExecutionContextWire.self, from: data)
    }

    public func withWorkflow(
        workflowID: String,
        kind: WorkflowKind,
        stepID: String? = nil,
        stepKind: String? = nil
    ) -> ExecutionContextWire {
        ExecutionContextWire(
            sessionID: sessionID,
            principal: resolvedPrincipal,
            turnID: turnID,
            agentID: agentID,
            workflow: WorkflowContextWire(
                workflowID: workflowID,
                kind: kind,
                stepID: stepID,
                stepKind: stepKind
            ),
            delivery: delivery,
            capabilities: capabilities
        )
    }

    public func withCapabilities(_ extra: [ExecutionContextCapability]) -> ExecutionContextWire {
        var merged = Set(capabilities)
        merged.formUnion(extra)
        return ExecutionContextWire(
            sessionID: sessionID,
            principal: resolvedPrincipal,
            turnID: turnID,
            agentID: agentID,
            workflow: workflow,
            delivery: delivery,
            capabilities: Array(merged).sorted { $0.rawValue < $1.rawValue }
        )
    }

    public var resolvedPrincipal: ServicePrincipal {
        if principal.hasPrefix("agent:") {
            let parts = principal.dropFirst(6).split(separator: "@", maxSplits: 1)
            if parts.count == 2 {
                return .agent(sessionID: String(parts[1]), agentID: String(parts[0]))
            }
        }
        switch principal {
        case "ui": return .ui
        case "system": return .system
        default:
            if principal.hasPrefix("job:") {
                return .job(jobID: String(principal.dropFirst(4)))
            }
            if principal.hasPrefix("webhook:") {
                return .webhook(source: String(principal.dropFirst(8)))
            }
            return .ui
        }
    }
}

public enum ExecutionContextWireError: Error, LocalizedError, Sendable {
    case invalidJSON
    case encodingFailed
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Execution context is not valid JSON."
        case .encodingFailed:
            return "Execution context could not be encoded."
        case .unsupportedSchemaVersion(let version):
            return "Unsupported execution context schema version \(version)."
        }
    }
}
