import ServiceContracts
import SwiftUI

@main
struct uiApp: App {
    @StateObject private var logStore = LogStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Captured at process start so Scene content cannot race AppDelegate.
    private let isPanelOnlyOrHeadlessLaunch =
        DerrickNotificationLaunch.isPollLaunch()
            || DerrickNotificationLaunch.isJobWorkerLaunch()
            || DerrickNotificationLaunch.isJobResultPresentationLaunch()

    init() {
        if DerrickNotificationLaunch.isJobResultPresentationLaunch() {
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
        // Distinct window id for panel-only so restored `derrick.main` ContentView is not reused.
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

/// Keeps a live `openWindow` handle so notification taps can recreate the UI after close.
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
        // Panel-only launches must not restore the main chat window from a prior session.
        !JobResultPanelSession.isPanelOnlyLaunch
            && !DerrickNotificationLaunch.isPollLaunch()
            && !DerrickNotificationLaunch.isJobWorkerLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !JobResultPanelSession.allowsTermination {
            fputs("[ui] cancel auto-terminate (job result panel active)\n", stderr)
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if DerrickNotificationLaunch.isJobWorkerLaunch()
            || DerrickNotificationLaunch.isPollLaunch()
            || DerrickNotificationLaunch.isJobResultPresentationLaunch()
        {
            return false
        }
        DerrickMainWindowBridge.ensureMainWindow()
        return true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserNotificationPoster.configureDelegateIfNeeded()
        if DerrickNotificationLaunch.isPollLaunch()
            || DerrickNotificationLaunch.isJobResultPresentationLaunch()
        {
            NSApp.setActivationPolicy(.accessory)
            if DerrickNotificationLaunch.isJobResultPresentationLaunch() {
                JobResultPanelSession.isPanelOnlyLaunch = true
                JobResultPanelSession.allowsTermination = false
                ProcessInfo.processInfo.disableAutomaticTermination("derrick.job-result-panel-launch")
                ProcessInfo.processInfo.disableSuddenTermination()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if DerrickNotificationLaunch.isPollLaunch() {
            Task { @MainActor in
                await DerrickNotificationService.shared.pollOnceAndFinish()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                JobResultPanelSession.allowsTermination = true
                NSApp.terminate(nil)
            }
            return
        }

        if let resultID = DerrickNotificationLaunch.jobResultIDToPresent()
            ?? DerrickJobResultPresentationWake.takePendingResultID()
        {
            let panelOnly = DerrickNotificationLaunch.isJobResultPresentationLaunch()
                || JobResultPanelSession.isPanelOnlyLaunch
            JobResultPresenter.interactiveSessionActive = !panelOnly
            if panelOnly {
                JobResultPanelSession.isPanelOnlyLaunch = true
                JobResultPanelSession.allowsTermination = false
                Task { @MainActor in
                    for window in NSApp.windows where !(window is NSPanel) {
                        window.orderOut(nil)
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
        DerrickNotificationService.shared.prepare()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !DerrickNotificationLaunch.isPollLaunch(),
              !DerrickNotificationLaunch.isJobWorkerLaunch(),
              !DerrickNotificationLaunch.isJobResultPresentationLaunch()
        else { return }
        DerrickNotificationService.shared.stop()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            try? JobServiceLoginAgent.ensureRegistered()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
    }
}
