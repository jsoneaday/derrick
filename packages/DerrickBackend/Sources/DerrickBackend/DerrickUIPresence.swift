import AppKit
import Foundation
import ServiceContracts

/// Whether the interactive `derrick.ui` app is running (any activation policy).
public enum DerrickUIPresence: Sendable {
    public static func isInteractiveUIRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: DerrickServiceID.ui.rawValue).isEmpty
    }
}
