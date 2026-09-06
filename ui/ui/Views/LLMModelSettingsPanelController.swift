import AppKit
import SwiftUI

@MainActor
final class LLMModelSettingsPanelController: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private var escapeMonitor: Any?

    func show(helperModelSettings: LLMModelSettings, modelThinkingSettings: LLMModelThinkingSettings) {
        if let window {
            center(window, relativeTo: preferredParentWindow())
            installEscapeMonitor()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: LLMModelSettingsView(
                helperModelSettings: helperModelSettings,
                modelThinkingSettings: modelThinkingSettings
            )
        )
        hostingController.sizingOptions = [.minSize]

        let panel = LLMModelSettingsWindowChrome.makeWindow(
            contentViewController: hostingController
        )
        panel.delegate = self
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
            frame.size = LLMModelSettingsWindowChrome.defaultContentSize
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

enum LLMModelSettingsWindowChrome {
    static let defaultContentSize = NSSize(width: 840, height: 560)
    static let minContentSize = NSSize(width: 800, height: 520)

    static var styleMask: NSWindow.StyleMask {
        [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    }

    /// Builds the Settings window with chrome set at init. Mutating `styleMask`
    /// after attaching a hosting controller leaves the traffic lights flush
    /// against the top-left edge.
    static func makeWindow(contentViewController: NSViewController) -> NSWindow {
        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings"
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = true
        panel.toolbarStyle = .unified
        panel.titlebarSeparatorStyle = .automatic
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentMinSize = minContentSize

        let toolbar = NSToolbar(identifier: "Derrick.Settings")
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        panel.toolbar = toolbar

        panel.contentViewController = contentViewController
        return panel
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
