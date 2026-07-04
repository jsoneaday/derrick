import Foundation
import MemorySystem
import PolicyEngine

public class ConversationCompletionContentPolicy: ResponseContentPolicy {
    private let policyEngine: PolicyEngine
    private let applicationName: String

    public init(policyEngine: PolicyEngine, applicationName: String) {
        self.policyEngine = policyEngine
        self.applicationName = applicationName
    }

    public func evaluateAssistantChunk(_ event: AssistantChunkEvent) async throws -> PolicyDecisionOutcome {
        let request = PolicyRequest(
            scope: "assistant_chunk",
            matcher: ChunkMatcher(
                contentLength: event.content.count,
                contentPreview: String(event.content.prefix(100))
            ),
            actor: "assistant"
        )

        let decision = try await policyEngine.decision(for: request)

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
                scope: "assistant_completion_content",
                matcher: CompletionContentMatcher(
                    patterns: foundPatterns,
                    completionLength: event.fullCompletion.count
                ),
                actor: "assistant"
            )

            let decision = try await policyEngine.decision(for: request)

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

private struct ChunkMatcher: Codable, Sendable {
    let contentLength: Int
    let contentPreview: String
}

private struct CompletionContentMatcher: Codable, Sendable {
    let patterns: [String]
    let completionLength: Int
}
