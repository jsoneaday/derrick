import Foundation

/// Single rule for guest/host `error` fields: nil, JSON null, or blank is **success**.
public enum PluginFailureSemantics: Sendable {
    public static func isFailure(_ error: String?) -> Bool {
        guard let error else { return false }
        return !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func isFailure(_ json: PluginJSON?) -> Bool {
        guard let json else { return false }
        switch json {
        case .null:
            return false
        case .string(let value):
            return isFailure(value)
        default:
            return true
        }
    }
}
