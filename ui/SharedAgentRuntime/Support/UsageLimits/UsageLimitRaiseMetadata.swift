import Foundation
import PolicyUserInteraction

/// Structured payload for usage-limit raise modals (JSON in `PolicyUserEvent.payloadPreview`).
struct UsageLimitRaiseMetadata: Codable, Sendable, Equatable {
    let dimension: String
    let currentLimit: Int
    let sessionProposedLimit: Int
    let presets: [Int]
    let absoluteMax: Int

    var dimensionEnum: UsageLimitDimension? {
        UsageLimitDimension(rawValue: dimension)
    }

    /// Presets strictly above the current effective limit, capped at absolute max.
    var selectablePresets: [Int] {
        presets
            .filter { $0 > currentLimit && $0 <= absoluteMax }
            .sorted()
    }

    static func encode(
        dimension: UsageLimitDimension,
        currentLimit: Int,
        sessionProposedLimit: Int,
        presets: [Int],
        absoluteMax: Int
    ) -> String? {
        let payload = UsageLimitRaiseMetadata(
            dimension: dimension.rawValue,
            currentLimit: currentLimit,
            sessionProposedLimit: sessionProposedLimit,
            presets: presets,
            absoluteMax: absoluteMax
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(from event: PolicyUserEvent) -> UsageLimitRaiseMetadata? {
        guard let preview = event.payloadPreview,
              let data = preview.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UsageLimitRaiseMetadata.self, from: data)
    }
}

enum UsageLimitRaiseOutcome: Sendable, Equatable {
    case stop
    case session(Int)
    case permanent(Int)
}

extension UsageLimitRaiseOutcome {
    var policyDecision: PolicyUserDecision {
        switch self {
        case .stop:
            return .denied(actor: "ui-stop")
        case .session(let limit):
            return .approvedOnce(actor: "ui-session:\(limit)")
        case .permanent(let limit):
            return .approvedPermanently(actor: "ui-permanent:\(limit)")
        }
    }

    static func parseLimit(from actor: String?) -> Int? {
        guard let actor else { return nil }
        for prefix in ["ui-permanent:", "ui-session:"] {
            if actor.hasPrefix(prefix) {
                return Int(actor.dropFirst(prefix.count))
            }
        }
        return nil
    }

    static func isPermanent(actor: String?) -> Bool {
        actor?.hasPrefix("ui-permanent:") == true
    }
}

enum UsageLimitFormatting {
    static func compact(_ value: Int) -> String {
        if value >= 1_000_000 {
            let millions = Double(value) / 1_000_000.0
            if millions.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(millions))M"
            }
            return String(format: "%.1fM", millions)
        }
        if value >= 1_000 {
            let thousands = Double(value) / 1_000.0
            if thousands.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(thousands))k"
            }
            return String(format: "%.0fk", thousands)
        }
        return "\(value)"
    }

    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
