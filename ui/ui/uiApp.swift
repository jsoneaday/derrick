import AppKit
import ServiceContracts
import ServiceEnsureUp
import SwiftUI

@main
struct uiApp: App {
    @StateObject private var logStore = LogStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Captured at process start so Scene content cannot race AppDelegate.
    private let isPanelOnlyOrHeadlessLaunch =
        DerrickNotificationLaunch.hasJobResultPresentationIntent()
            || DerrickNotificationLaunch.hasHITLApprovalPresentationIntent()

    init() {
        if DerrickNotificationLaunch.hasJobResultPresentationIntent()
            || DerrickNotificationLaunch.hasHITLApprovalPresentationIntent() {
            JobResultPanelSession.isPanelOnlyLaunch = true
            JobResultPanelSession.allowsTermination = false
        }
        RuntimeLog.shared.addSink { message in
            Task { @MainActor in
                DebugLogStore.shared.log(message)
            }
        }
    }

    var body: some Scene {
        let panelOnly = isPanelOnlyOrHeadlessLaunch || JobResultPanelSession.isPanelOnlyLaunch
        WindowGroup(
            panelOnly ? "Derrick Result" : "Derrick",
            id: panelOnly ? "derrick.job-result-panel" : DerrickMainWindowID.main
        ) {
            if panelOnly {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            } else {
                ContentView()
                    .environmentObject(logStore)
                    .preferredColorScheme(.light)
                    .background(DerrickMainWindowRegistrar())
            }
        }
    }
}

private enum DerrickMainWindowID {
    static let main = "derrick.main"
}

private struct DerrickMainWindowRegistrar: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                DerrickMainWindowBridge.openMainWindow = {
                    openWindow(id: DerrickMainWindowID.main)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .derrickEnsureMainWindow)) { _ in
                openWindow(id: DerrickMainWindowID.main)
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        !JobResultPanelSession.isPanelOnlyLaunch
            && !DerrickNotificationLaunch.hasJobResultPresentationIntent()
            && !DerrickNotificationLaunch.hasHITLApprovalPresentationIntent()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !JobResultPanelSession.allowsTermination {
            fputs("[ui] cancel auto-terminate (panel-only session active)\n", stderr)
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if DerrickNotificationLaunch.hasJobResultPresentationIntent()
            || DerrickNotificationLaunch.hasHITLApprovalPresentationIntent()
        {
            return false
        }
        DerrickMainWindowBridge.ensureMainWindow()
        return true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserNotificationPoster.configureDelegateIfNeeded()
        ServiceEnsureUpHooks.beforeEnsureDaemon = nil
        if DerrickNotificationLaunch.hasJobResultPresentationIntent()
            || DerrickNotificationLaunch.hasHITLApprovalPresentationIntent()
        {
            NSApp.setActivationPolicy(.accessory)
            if DerrickNotificationLaunch.hasJobResultPresentationIntent()
                || DerrickNotificationLaunch.hasHITLApprovalPresentationIntent() {
                JobResultPanelSession.isPanelOnlyLaunch = true
                JobResultPanelSession.allowsTermination = false
                ProcessInfo.processInfo.disableAutomaticTermination("derrick.panel-only-launch")
                ProcessInfo.processInfo.disableSuddenTermination()
                dismissRestoredMainWindows()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let approvalID = DerrickNotificationLaunch.hitlApprovalIDToPresent()
            ?? DerrickHITLApprovalPresentationWake.takePendingApprovalID()
        {
            let panelOnly = DerrickNotificationLaunch.hasHITLApprovalPresentationIntent()
                || JobResultPanelSession.isPanelOnlyLaunch
            JobResultPresenter.interactiveSessionActive = !panelOnly
            JobResultPanelSession.isPanelOnlyLaunch = panelOnly
            JobResultPanelSession.allowsTermination = false
            if panelOnly {
                dismissRestoredMainWindows()
            }
            DerrickNotificationService.shared.prepare()
            Task { @MainActor in
                if panelOnly {
                    for window in NSApp.windows where !(window is NSPanel) {
                        window.orderOut(NSApp)
                    }
                }
                await DerrickNotificationService.shared.presentHITLApprovalWhenReady(id: approvalID)
            }
            return
        }

        if let resultID = DerrickNotificationLaunch.jobResultIDToPresent()
            ?? DerrickJobResultPresentationWake.takePendingResultID()
        {
            let panelOnly = DerrickNotificationLaunch.hasJobResultPresentationIntent()
                || JobResultPanelSession.isPanelOnlyLaunch
            JobResultPresenter.interactiveSessionActive = !panelOnly
            if panelOnly {
                JobResultPanelSession.isPanelOnlyLaunch = true
                JobResultPanelSession.allowsTermination = false
                dismissRestoredMainWindows()
                Task { @MainActor in
                    for window in NSApp.windows where !(window is NSPanel) {
                        window.orderOut(NSApp)
                    }
                    DerrickNotificationService.shared.prepare()
                    await DerrickNotificationService.shared.presentJobResultWhenReady(id: resultID)
                }
            } else {
                JobResultPresenter.interactiveSessionActive = true
                DerrickNotificationService.shared.prepare()
                Task { @MainActor in
                    await DerrickNotificationService.shared.presentJobResultWhenReady(id: resultID)
                }
            }
            return
        }

        JobResultPresenter.interactiveSessionActive = true
        HITLLiveApprovalHandlers.wireAgentServiceClient()
        DerrickNotificationService.shared.prepare()
        if !DerrickNotificationLaunch.hasJobResultPresentationIntent()
            && !DerrickNotificationLaunch.hasHITLApprovalPresentationIntent() {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { await DaemonBootstrapCoordinator.prepareForHostApp(force: false) }
            }
        }
    }

    private var activationObserver: NSObjectProtocol?

    func applicationWillTerminate(_ notification: Notification) {
        guard !DerrickNotificationLaunch.hasJobResultPresentationIntent(),
              !DerrickNotificationLaunch.hasHITLApprovalPresentationIntent()
        else { return }
        DerrickUISessionPresence.clearInteractiveSession()
        DerrickNotificationService.shared.stop()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            try? JobServiceLoginAgent.ensureRegistered()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
    }

    private func dismissRestoredMainWindows() {
        for window in NSApp.windows {
            let id = window.identifier?.rawValue ?? ""
            if id == DerrickMainWindowID.main || window.title == "Derrick" {
                window.isRestorable = false
                window.orderOut(NSApp)
                window.close()
            }
        }
    }
}
