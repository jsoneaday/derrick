import Foundation
import Combine
import DBRepository
import PolicyRuntime
import AppEvents
import PolicyUserInteraction

/// App-owned permanent/session grants that skip content-confirm for sensitivity categories.
/// Mirrors egress once/always; not an MCP tool; not stored as policy rules.
@MainActor
final class ContentSensitivityGrantService: ObservableObject {
    static let shared = ContentSensitivityGrantService()

    /// Categories that settings / always-allow may grant. SSN stays hard-deny via policy rules.
    static let grantableCategories: [(id: String, title: String, detail: String)] = [
        ("email", "Email addresses", "Allow assistant replies that include email addresses without prompting."),
        ("phone", "Phone numbers", "Allow assistant replies that include phone numbers without prompting.")
    ]

    @Published private(set) var permanentGrants: [ContentSensitivityGrant] = []

    private var repository: DBRepository?
    /// Session-scoped category allows (also persisted with scope=session for audit).
    private var sessionAllowedCategories: [String: Set<String>] = [:]

    private init() {}

    func configure(repository: DBRepository) async {
        self.repository = repository
        do {
            try await reloadPermanent()
        } catch {
            debugLog("Content sensitivity grants configure failed: \(error.localizedDescription)")
        }
    }

    func reloadPermanent() async throws {
        guard let repository else {
            permanentGrants = []
            return
        }
        permanentGrants = try await repository.loadContentSensitivityGrants(permanentOnly: true)
    }

    func isPermanentlyGranted(_ category: String) -> Bool {
        let cat = category.lowercased()
        return permanentGrants.contains { $0.enabled && $0.category == cat }
    }

    func isGranted(_ category: String, sessionID: String) -> Bool {
        let cat = category.lowercased()
        if isPermanentlyGranted(cat) { return true }
        return sessionAllowedCategories[sessionID]?.contains(cat) == true
    }

    /// Categories present in text that still need a user grant for confirm flows.
    func ungrantedConfirmableCategories(in text: String, sessionID: String) -> [String] {
        let detected = Set(detectSensitivePatterns(in: text).map { $0.lowercased() })
        let grantable = Set(Self.grantableCategories.map(\.id))
        return detected
            .intersection(grantable)
            .filter { !isGranted($0, sessionID: sessionID) }
            .sorted()
    }

    /// Hold further *complete* UI deltas only when ungranted **email** appears.
    /// Thinking/tool_call still stream. Other text streams normally so the UI does not feel stalled.
    /// Phone is grantable in Settings but does not hold mid-stream (less common; flushed at end).
    func shouldHoldCompleteStreaming(for text: String, sessionID: String) -> Bool {
        let detected = Set(detectSensitivePatterns(in: text).map { $0.lowercased() })
        return detected.contains("email") && !isGranted("email", sessionID: sessionID)
    }

    func setPermanentGrant(category: String, enabled: Bool, actor: String? = "ui-user") async throws {
        let cat = category.lowercased()
        guard Self.grantableCategories.contains(where: { $0.id == cat }) else {
            throw NSError(
                domain: "ContentSensitivity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Category “\(category)” cannot be permanently allowed."]
            )
        }
        guard let repository else { return }
        if enabled {
            try await repository.saveContentSensitivityGrant(
                ContentSensitivityGrant(
                    category: cat,
                    scope: "permanent",
                    actor: actor,
                    enabled: true
                )
            )
        } else {
            try await repository.deletePermanentContentSensitivityGrant(category: cat)
        }
        try await reloadPermanent()
    }

    func grantSession(categories: [String], sessionID: String, actor: String?) async {
        let cats = categories.map { $0.lowercased() }
        var set = sessionAllowedCategories[sessionID] ?? []
        for cat in cats { set.insert(cat) }
        sessionAllowedCategories[sessionID] = set

        guard let repository else { return }
        for cat in cats {
            do {
                try await repository.saveContentSensitivityGrant(
                    ContentSensitivityGrant(
                        category: cat,
                        scope: "session",
                        sessionID: sessionID,
                        actor: actor,
                        enabled: true
                    )
                )
            } catch {
                debugLog("Failed to persist session content grant \(cat): \(error.localizedDescription)")
            }
        }
    }

    func grantPermanent(categories: [String], actor: String?) async throws {
        for cat in categories {
            try await setPermanentGrant(category: cat, enabled: true, actor: actor)
        }
    }

    /// After policy returns confirm: apply grants or prompt once/always/deny.
    /// - Returns: content to accept, or nil if denied/cancelled.
    func resolveConfirm(
        content: String,
        requiredFields: [String],
        sessionID: String
    ) async -> String? {
        let pending = ungrantedConfirmableCategories(in: content, sessionID: sessionID)
        if pending.isEmpty {
            // Policy said confirm but grants already cover grantable patterns (or none grantable).
            return content
        }

        let labels = pending.map { cat in
            Self.grantableCategories.first(where: { $0.id == cat })?.title ?? cat
        }
        let event = PolicyUserEventFactory.contentSensitivityAccessRequest(
            categories: labels,
            categoryIds: pending,
            payloadPreview: String(content.prefix(800)),
            correlationId: sessionID
        )
        let decision = await AppEventBus.shared.initDecision(event)
        switch decision {
        case .approved(let actor), .approvedOnce(let actor):
            debugLog("Content sensitivity allow once for \(pending.joined(separator: ",")) by \(actor ?? "user")")
            await grantSession(categories: pending, sessionID: sessionID, actor: actor)
            return content
        case .approvedPermanently(let actor):
            debugLog("Content sensitivity allow always for \(pending.joined(separator: ",")) by \(actor ?? "user")")
            do {
                try await grantPermanent(categories: pending, actor: actor)
            } catch {
                debugLog("Failed permanent content grants: \(error.localizedDescription)")
                await AppEventBus.shared.publish(
                    PolicyUserEventFactory.contentGovernanceDenied(
                        reason: "Failed to save always-allow for sensitive content: \(error.localizedDescription)",
                        payloadPreview: String(content.prefix(800)),
                        correlationId: sessionID
                    )
                )
                return nil
            }
            return content
        case .denied(let actor):
            debugLog("Content sensitivity deny by \(actor ?? "user")")
            await AppEventBus.shared.publish(
                PolicyUserEventFactory.contentGovernanceDenied(
                    reason: "User denied assistant content that may include sensitive data (\(labels.joined(separator: ", "))).",
                    payloadPreview: String(content.prefix(800)),
                    correlationId: sessionID
                )
            )
            return nil
        case .dismissed, .timedOut:
            await AppEventBus.shared.publish(
                PolicyUserEventFactory.contentGovernanceDenied(
                    reason: "Sensitive content was not approved.",
                    payloadPreview: String(content.prefix(800)),
                    correlationId: sessionID
                )
            )
            return nil
        }
    }
}
