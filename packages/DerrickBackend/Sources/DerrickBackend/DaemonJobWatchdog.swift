import AppKit
import DBRepository
import Foundation
import ServiceContracts

/// Watches SQLite for due jobs and wakes a headless UI worker when the interactive app is gone.
///
/// Temporary until Job/Agent fold into derrickd: embedded XPCs die with the UI process, so
/// scheduled work cannot run (or notify) after Cmd+Q without this wake.
public actor DaemonJobWatchdog {
    public static let shared = DaemonJobWatchdog()

    private var task: Task<Void, Never>?
    private var lastWakeAt: Date?
    private let pollNanoseconds: UInt64 = 2_000_000_000
    private let wakeCooldown: TimeInterval = 20

    public func start() {
        guard task == nil else { return }
        task = Task { await loop() }
        fputs("[derrickd] job watchdog started\n", stderr)
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            do {
                try await tick()
            } catch {
                fputs("[derrickd] job watchdog tick failed: \(error.localizedDescription)\n", stderr)
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }

    private func tick() async throws {
        let repo = try await DaemonRuntime.shared.sharedRepository()
        let due = try await repo.hasDueOrRunningJobs()
        guard due else { return }

        if isUIProcessRunning() {
            return
        }

        if let lastWakeAt, Date().timeIntervalSince(lastWakeAt) < wakeCooldown {
            return
        }

        lastWakeAt = Date()
        fputs("[derrickd] due jobs with UI quit — waking headless job worker\n", stderr)
        await DaemonUILauncher.wakeJobWorker()
    }

    private func isUIProcessRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: DerrickServiceID.ui.rawValue).isEmpty
    }
}
