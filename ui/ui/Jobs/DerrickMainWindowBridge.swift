import AppKit
import Foundation

extension Notification.Name {
    static let derrickEnsureMainWindow = Notification.Name("derrick.ensureMainWindow")
}

/// Bridges AppKit notification taps / reopen to SwiftUI `openWindow`.
@MainActor
enum DerrickMainWindowBridge {
    static var openMainWindow: (() -> Void)?

    static func ensureMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let visible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if visible {
            NSApp.windows.filter(\.isVisible).forEach { $0.makeKeyAndOrderFront(nil) }
            return
        }
        if let openMainWindow {
            openMainWindow()
        } else {
            NotificationCenter.default.post(name: .derrickEnsureMainWindow, object: nil)
        }
    }
}
