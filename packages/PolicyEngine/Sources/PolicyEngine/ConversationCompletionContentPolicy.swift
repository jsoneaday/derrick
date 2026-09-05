import Foundation
import MemorySystem
import Structure

public final class ConversationCompletionContentPolicy: PolicyEvaluator {
    private let policyEngine: PolicyEngine
    private let applicationName: String

    public init(policyEngine: PolicyEngine, applicationName: String) {
        self.policyEngine = policyEngine
        self.applicationName = applicationName
    }

    public func evaluateAssistantChunk(_ event: AssistantChunkEvent) async throws -> PolicyDecisionOutcome {
        let request = PolicyRequest(
            call: ToolCall(
                name: "assistant_chunk",
                arguments: [
                    "contentLength": String(event.content.count),
                    "contentPreview": String(event.content.prefix(100))
                ],
                effects: .readsState,
                risk: .low
            ),
            context: PolicyContext(agentID: applicationName, caller: "assistant")
        )

        let decision = policyEngine.decision(for: request)

        switch decision {
        case .allow:
            return .allow
        case .deny:
            return .deny(reason: "Policy engine denied assistant chunk")
        case .confirm:
            return .confirm(requiredFields: [])
        }
    }

    public func evaluateAssistantCompletion(_ event: AssistantCompletionEvent) async throws -> PolicyDecisionOutcome {
        let patterns = try? detectSensitivePatterns(in: event.fullCompletion)

        if let foundPatterns = patterns, !foundPatterns.isEmpty {
            let request = PolicyRequest(
                call: ToolCall(
                    name: "assistant_completion_content",
                    arguments: [
                        "patterns": foundPatterns.joined(separator: ","),
                        "completionLength": String(event.fullCompletion.count)
                    ],
                    effects: .readsState,
                    risk: .low
                ),
                context: PolicyContext(agentID: applicationName, caller: "assistant")
            )

            let decision = policyEngine.decision(for: request)

            switch decision {
            case .allow:
                return .allow
            case .deny:
                return .deny(reason: "Completion contains sensitive content (patterns: \(foundPatterns.joined(separator: ", ")))")
            case .confirm:
                return .confirm(requiredFields: ["review_confirmation"])
            }
        }

        return .allow
    }

    private func detectSensitivePatterns(in text: String) throws -> [String] {
        var detected: [String] = []

        let emailPattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"
        if try NSRegularExpression(pattern: emailPattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            detected.append("email")
        }

        let phonePattern = "\\b\\d{3}[-.]?\\d{3}[-.]?\\d{4}\\b"
        if try NSRegularExpression(pattern: phonePattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            detected.append("phone")
        }

        let ssnPattern = "\\b\\d{3}-\\d{2}-\\d{4}\\b"
        if try NSRegularExpression(pattern: ssnPattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            detected.append("ssn")
        }

        return detected
    }
}

