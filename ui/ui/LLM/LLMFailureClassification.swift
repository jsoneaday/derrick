import Foundation
import Combine
import LLMAgentClient

enum LLMFailureContext: Equatable, Sendable {
    case outOfCredits(provider: String)
    case generic(provider: String, message: String)
}

@MainActor
final class LLMFailureReporter: ObservableObject, @unchecked Sendable {
    static let shared = LLMFailureReporter()

    @Published private(set) var latest: LLMFailureContext?

    func report(_ context: LLMFailureContext) {
        latest = context
    }

    func clear() {
        latest = nil
    }
}

struct LLMFailureClassifier {
    static func classify(_ error: Error, provider: LLMProviderChoice) -> LLMFailureContext {
        let message = error.localizedDescription.lowercased()
        let providerName = provider.displayName

        let creditIndicators = [
            "quota",
            "insufficient_quota",
            "credits",
            "billing",
            "payment",
            "exceeded",
            "limit",
            "rate limit",
            "too many requests",
            "429"
        ]

        if isCreditRelated(message: message, indicators: creditIndicators) {
            return .outOfCredits(provider: providerName)
        }

        return .generic(provider: providerName, message: error.localizedDescription)
    }

    private static func isCreditRelated(message: String, indicators: [String]) -> Bool {
        for indicator in indicators {
            if message.contains(indicator) {
                return true
            }
        }
        return false
    }
}

extension LLMFailureContext {
    var title: String {
        switch self {
        case .outOfCredits:
            return "API Credits Exhausted"
        case .generic:
            return "Model Request Failed"
        }
    }

    var message: String {
        switch self {
        case .outOfCredits(let provider):
            return "Your \(provider) account appears to be out of API credits or has hit its usage limit. Please check billing and quota, then try again."
        case .generic(let provider, let detail):
            return "The \(provider) model request failed.\n\n\(detail)"
        }
    }
}
