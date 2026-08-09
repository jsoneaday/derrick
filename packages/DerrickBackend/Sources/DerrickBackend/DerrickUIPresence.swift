import Foundation
import ServiceContracts

/// Whether the interactive `derrick.ui` app is running and ready for chat.
public enum DerrickUIPresence: Sendable {
    public static func isInteractiveUIRunning() -> Bool {
        DerrickUISessionPresence.isInteractiveSessionActive()
    }
}
