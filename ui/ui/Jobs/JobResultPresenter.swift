import AppKit
import Combine
import Foundation
import ServiceContracts
import UserNotifications
import DBRepository

/// Holds pending job results and drives modal presentation + user notifications.
@MainActor
final class JobResultPresenter: ObservableObject {
    static let shared = JobResultPresenter()

    @Published private(set) var activeResult: JobResultDTO?
    @Published private(set) var isPresented: Bool = false

    private var queue: [JobResultDTO] = []
    private var seenIDs: Set<String> = []
    private var repository: DBRepository?

    private init() {
        JobResultNotificationPoster.requestAuthorizationIfNeeded()
    }

    /// Optional shared DB for loading results after cold launch / notification click.
    func configure(repository: DBRepository) {
        self.repository = repository
    }

    /// Called from reverse XPC when a job wake completes while UI is up.
    func enqueue(_ result: JobResultDTO) {
        guard !seenIDs.contains(result.id) else { return }
        seenIDs.insert(result.id)

        // Prefer modal when app is active and frontmost; always notify when not active
        // so closing the window (or switching apps) still surfaces the result.
        let appActive = NSApp.isActive
        if isPresented {
            queue.append(result)
            if !appActive {
                JobResultNotificationPoster.post(result: result)
            }
            return
        }
        if appActive {
            present(result)
        } else {
            queue.append(result)
            JobResultNotificationPoster.post(result: result)
        }
    }

    func present(_ result: JobResultDTO) {
        seenIDs.insert(result.id)
        activeResult = result
        isPresented = true
        NSApp.activate(ignoringOtherApps: true)
        markRead(resultID: result.id)
    }

    func dismiss() {
        isPresented = false
        activeResult = nil
        if let next = queue.first {
            queue.removeFirst()
            present(next)
        }
    }

    /// Open a result from a notification click (by result id, queue, or DB).
    func openFromNotification(resultID: String?) {
        if let resultID,
           let queued = queue.first(where: { $0.id == resultID }) {
            queue.removeAll { $0.id == resultID }
            present(queued)
            return
        }
        if let first = queue.first {
            queue.removeFirst()
            present(first)
            return
        }
        if let resultID, let repo = repository {
            Task {
                if let row = try? await repo.fetchJobResult(id: resultID) {
                    let dto = JobResultDTO(
                        id: row.id,
                        jobID: row.jobID,
                        jobSessionID: row.jobSessionID,
                        parentSessionID: row.parentSessionID,
                        responseText: row.responseText,
                        createdAt: row.createdAt
                    )
                    await MainActor.run { self.present(dto) }
                    return
                }
            }
        }
        // Load any unread from DB as fallback.
        loadUnreadFromDatabase()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Call after DB is ready (bootstrap) so results finished while UI was quit appear.
    /// Only surfaces **recent** unread results (last 24h) so an old unread row does not
    /// re-open a modal on every launch if mark-read failed once.
    func loadUnreadFromDatabase() {
        guard let repo = repository else { return }
        Task {
            let rows = (try? await repo.fetchUnreadJobResults(limit: 20)) ?? []
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            await MainActor.run {
                for row in rows.reversed() where row.createdAt >= cutoff {
                    let dto = JobResultDTO(
                        id: row.id,
                        jobID: row.jobID,
                        jobSessionID: row.jobSessionID,
                        parentSessionID: row.parentSessionID,
                        responseText: row.responseText,
                        createdAt: row.createdAt
                    )
                    if !self.seenIDs.contains(dto.id) {
                        self.seenIDs.insert(dto.id)
                        if self.isPresented {
                            self.queue.append(dto)
                        } else {
                            self.present(dto)
                        }
                    }
                }
                // Best-effort: mark older unread as read so they stop reappearing forever.
                for row in rows where row.createdAt < cutoff {
                    self.markRead(resultID: row.id)
                }
            }
        }
    }

    private func markRead(resultID: String) {
        guard let repo = repository else {
            fputs("[JobResult] markRead skipped — no repository\n", stderr)
            return
        }
        Task {
            do {
                try await repo.markJobResultRead(id: resultID)
                fputs("[JobResult] marked read id=\(resultID)\n", stderr)
            } catch {
                fputs("[JobResult] markRead failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }
}

/// App-level notification delegate: click opens job result modal.
final class JobResultNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = JobResultNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner even if app is frontmost (modal is primary when active via enqueue).
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let resultID = info[JobResultNotificationPoster.resultIDKey] as? String
        Task { @MainActor in
            JobResultPresenter.shared.openFromNotification(resultID: resultID)
        }
        completionHandler()
    }
}
