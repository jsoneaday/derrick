import ServiceContracts
import SwiftUI

@main
struct uiApp: App {
    @StateObject private var logStore = LogStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var isNotificationPollLaunch: Bool {
        DerrickNotificationLaunch.isPollLaunch()
    }

    init() {
        RuntimeLog.shared.addSink { message in
            Task { @MainActor in
                DebugLogStore.shared.log(message)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            if isNotificationPollLaunch {
                EmptyView()
            } else {
                ContentView()
                    .environmentObject(logStore)
                    .preferredColorScheme(.light)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !DerrickNotificationLaunch.isPollLaunch()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserNotificationPoster.configureDelegateIfNeeded()
        if DerrickNotificationLaunch.isPollLaunch() {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if DerrickNotificationLaunch.isPollLaunch() {
            Task { @MainActor in
                await DerrickNotificationService.shared.pollOnceAndFinish()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                NSApp.terminate(nil)
            }
            return
        }
        DerrickNotificationService.shared.prepare()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !DerrickNotificationLaunch.isPollLaunch() else { return }
        DerrickNotificationService.shared.stop()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            try? JobServiceLoginAgent.ensureRegistered()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
    }
}
