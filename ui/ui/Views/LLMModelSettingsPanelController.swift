import AppKit
import SwiftUI

@MainActor
final class LLMModelSettingsPanelController: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?

    func show(helperModelSettings: LLMModelSettings) {
        if let window {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: LLMModelSettingsView(helperModelSettings: helperModelSettings)
        )
        let panel = NSWindow(
            contentViewController: hostingController
        )
        panel.styleMask = [.titled, .closable, .miniaturizable]
        panel.title = "Helper models"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentMinSize = NSSize(width: 760, height: 440)
        panel.center()
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        window = panel

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else {
            return
        }
        window = nil
    }
}
