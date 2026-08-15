import AppKit
import SwiftUI

@MainActor
final class LLMModelSettingsPanelController: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private var escapeMonitor: Any?

    func show(helperModelSettings: LLMModelSettings) {
        if let window {
            center(window, relativeTo: preferredParentWindow())
            installEscapeMonitor()
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
        panel.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        panel.title = "Settings"
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = false
        panel.isReleasedWhenClosed = false
        // Stay with the app; floating level often looks detached from the main window.
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentMinSize = NSSize(width: 800, height: 520)
        panel.setContentSize(NSSize(width: 840, height: 560))
        panel.delegate = self
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        center(panel, relativeTo: preferredParentWindow())
        window = panel
        installEscapeMonitor()

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else {
            return
        }
        removeEscapeMonitor()
        window = nil
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 53 else {
                return event
            }
            self.window?.performClose(nil)
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    private func preferredParentWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, key !== window {
            return key
        }
        if let main = NSApp.mainWindow, main !== window {
            return main
        }
        return NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.canBecomeMain })
    }

    /// Center on the parent app window when possible; otherwise screen center.
    private func center(_ panel: NSWindow, relativeTo parent: NSWindow?) {
        panel.layoutIfNeeded()
        var frame = panel.frame
        if frame.width < 1 || frame.height < 1 {
            frame.size = NSSize(width: 840, height: 560)
        }

        if let parent {
            let parentFrame = parent.frame
            frame.origin.x = parentFrame.midX - frame.width / 2
            frame.origin.y = parentFrame.midY - frame.height / 2
            if let screen = parent.screen ?? NSScreen.main {
                frame = frame.constrained(to: screen.visibleFrame)
            }
            panel.setFrame(frame, display: true)
        } else {
            panel.center()
        }
    }
}

private extension NSRect {
    func constrained(to bounds: NSRect) -> NSRect {
        var frame = self
        if frame.maxX > bounds.maxX {
            frame.origin.x = bounds.maxX - frame.width
        }
        if frame.maxY > bounds.maxY {
            frame.origin.y = bounds.maxY - frame.height
        }
        if frame.minX < bounds.minX {
            frame.origin.x = bounds.minX
        }
        if frame.minY < bounds.minY {
            frame.origin.y = bounds.minY
        }
        return frame
    }
}
