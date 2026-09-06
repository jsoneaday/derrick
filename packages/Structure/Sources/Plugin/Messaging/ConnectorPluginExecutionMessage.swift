import Foundation

/// User-facing copy when a saved connector fails while talking to the vendor.
public enum ConnectorPluginExecutionMessage: Sendable {
    public static let tookTooManySteps = """
    The connector could not finish loading in one pass. Try opening it again.
    """

    public static func userFacing(fromDetail detail: String) -> String? {
        let lowered = detail.lowercased()
        if lowered.contains("hop budget exceeded") || lowered.contains("hop http limit") {
            return tookTooManySteps
        }
        return nil
    }
}
