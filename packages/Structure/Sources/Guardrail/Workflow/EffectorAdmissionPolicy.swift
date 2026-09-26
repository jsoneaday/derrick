import Foundation

/// Helpers for effector execution context. Admission itself is Policy (`tool_invocation` rules).
public enum EffectorAdmissionPolicy: Sendable {
    public static func parseContextJSON(_ json: String?) -> ExecutionContextWire? {
        guard let json,
              !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try? ExecutionContextWire.decodeJSON(json)
    }
}
