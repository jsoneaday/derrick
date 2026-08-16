import Combine
import Foundation
import Plugin

@MainActor
final class CreatePluginWizardStore: ObservableObject {
    static let shared = CreatePluginWizardStore()

    enum Phase: Equatable {
        case editing
        case reviewing
        case reviewed
    }

    @Published var isPresented = false
    @Published var request = ""
    @Published var phase: Phase = .editing
    @Published var review: CreatePluginPromptReview?
    @Published var reviewError: String?

    private init() {}

    func present(goal: String) {
        request = Self.prefill(from: goal)
        phase = .editing
        review = nil
        reviewError = nil
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        review = nil
        reviewError = nil
        phase = .editing
    }

    var canSubmit: Bool {
        !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .reviewing
    }

    var factoryKickoff: String {
        let user = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let plugin = (review?.pluginDoes ?? user).trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = review?.chatDoes.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parts = [plugin]
        if !chat.isEmpty {
            parts.append("After this plugin runs, chat should: \(chat)")
            parts.append("The plugin collects or computes. Chat writes what the user reads.")
        }
        if !user.isEmpty, user != plugin {
            parts.append("User request: \(user)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// First submit reviews. After a review exists, Create plugin starts factory with no second review.
    func submit(settings: LLMModelSettings) async -> Bool {
        if review != nil, phase == .reviewed {
            return true
        }
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        phase = .reviewing
        reviewError = nil
        do {
            let result = try await CreatePluginPromptReviewer.review(
                request: trimmed,
                previous: nil,
                settings: settings
            )
            review = result
            phase = .reviewed
            debugLog(
                "[skill] create-plugin prompt review ok=\(result.ok) questions=\(result.questions.count) plugin=\(result.pluginDoes.prefix(80))"
            )
            return false
        } catch {
            review = nil
            reviewError = error.localizedDescription
            phase = .editing
            debugLog("[skill] create-plugin prompt review failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func prefill(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("that ") {
            text = String(text.dropFirst(5))
        }
        return text
    }
}
