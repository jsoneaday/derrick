import AppKit
import DBRepository
import Foundation
import PolicyUserInteraction
import ServiceContracts
import UserNotifications

/// Payload keys shared between notification post and delegate handling.
enum DerrickNotificationPayload {
    static let kindKey = "kind"
    static let approvalIDKey = "approvalID"
    static let jobResultIDKey = "jobResultID"

    static let kindHITL = "hitl-approval"
    static let kindJobResult = "job-result"

    static let categoryHITL = "derrick.hitl-approval"
}

/// Single macOS notification path for scheduled-job HITL and job completion.
///
/// Delivery rules:
/// - Live chat HITL (UI connected): modal via `HITLLiveApprovalHandlers` — no notification.
/// - Scheduled job HITL: notification always (even when UI is open); tap → Allow/Deny alert.
/// - Job completion: notification always (chat is not interrupted).
/// - Info/errors during UI session: modal only (`PolicyEventPresenter`), never notifications.
@MainActor
final class DerrickNotificationService {
    static let shared = DerrickNotificationService()

    private var repository: DBRepository?
    private var pollTask: Task<Void, Never>?
    private var darwinObserver: UnsafeMutableRawPointer?
    private var postingIDs: Set<String> = []
    private let pollIntervalNanoseconds: UInt64 = 2_000_000_000
    private let launchEpoch = Date()
    private var sessionReady = false
    private var headlessPoll = false
    private var activationObserver: NSObjectProtocol?

    private init() {}

    func configure(repository: DBRepository) {
        self.repository = repository
    }

    func prepare() {
        UserNotificationPoster.configureDelegateIfNeeded()
        registerCategories()
        registerDarwinObserver()
    }

    func activateSession(repository: DBRepository) async {
        self.repository = repository
        sessionReady = true
        let cancelled = (try? await repository.cancelPendingHITLApprovals(
            createdBefore: launchEpoch,
            actor: "ui-launch-reset"
        )) ?? 0
        if cancelled > 0 {
            fputs("[HumanDecision] cancelled \(cancelled) stale pending approval(s) at launch\n", stderr)
        }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        registerAppActivationObserver()
        startPollingIfNeeded()
    }

    func start() {
        headlessPoll = true
        prepare()
        startPollingIfNeeded()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        unregisterDarwinObserver()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    func pollOnceAndFinish() async {
        headlessPoll = true
        prepare()
        _ = await UserNotificationPoster.requestAuthorizationIfNeeded()
        _ = await ensureRepository()
        await pollAndPost()
    }

    func handleResponse(
        actionIdentifier: String,
        kind: String?,
        approvalID: String?,
        jobResultID: String?
    ) async {
        guard let kind else { return }
        guard await ensureRepository() != nil else {
            fputs("[HumanDecision] handleResponse: no repository\n", stderr)
            return
        }

        switch kind {
        case DerrickNotificationPayload.kindHITL:
            guard let approvalID else { return }
            switch actionIdentifier {
            case UNNotificationDefaultActionIdentifier:
                await resolveHITLFromNotificationTap(approvalID: approvalID)
            case UNNotificationDismissActionIdentifier:
                fputs("[HumanDecision] dismissed id=\(approvalID) (no decision)\n", stderr)
            default:
                fputs("[HumanDecision] unhandled action=\(actionIdentifier)\n", stderr)
            }
        case DerrickNotificationPayload.kindJobResult:
            guard let jobResultID else { return }
            switch actionIdentifier {
            case UNNotificationDefaultActionIdentifier:
                await presentJobResultFromNotificationTap(id: jobResultID)
            case UNNotificationDismissActionIdentifier:
                await markJobResultRead(id: jobResultID)
            default:
                await presentJobResultFromNotificationTap(id: jobResultID)
            }
        default:
            break
        }
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task {
            _ = await UserNotificationPoster.requestAuthorizationIfNeeded()
            await pollAndPost()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                await pollAndPost()
            }
        }
    }

    private func ensureRepository() async -> DBRepository? {
        if let repository { return repository }
        do {
            let directory = try DerrickAppSupport.databaseDirectory()
            let repo = try await ConversationModel.makeMemoryStore(
                applicationName: DerrickAppSupport.defaultApplicationName,
                databaseDirectoryURL: directory
            )
            repository = repo
            await EgressAllowlistService.shared.configure(repository: repo)
            return repo
        } catch {
            fputs("[HumanDecision] ensureRepository failed: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    private func pollAndPost() async {
        guard headlessPoll || sessionReady else { return }
        guard await ensureRepository() != nil else { return }
        guard let repository else { return }
        await postPendingHITL(repository: repository)
        await postPendingJobResults(repository: repository)
    }

    private func postPendingHITL(repository: DBRepository) async {
        let rows = (try? await repository.fetchPendingHITLApprovalsNeedingNotify()) ?? []
        for row in rows {
            if postingIDs.contains(row.id) { continue }
            guard shouldNotifyForHITL(row) else { continue }
            guard row.createdAt >= launchEpoch || headlessPoll else {
                try? await repository.resolveHITLApproval(
                    id: row.id,
                    status: .cancelled,
                    editedArgumentsJSON: nil,
                    actor: "ui-stale-skip"
                )
                continue
            }
            guard (try? await repository.claimHITLNotificationPost(id: row.id)) == true else { continue }
            postingIDs.insert(row.id)
            await postHITLNotification(row: row, repository: repository)
        }
    }

    private func postHITLNotification(row: PendingHITLApprovalRow, repository: DBRepository) async {
        let isNetwork = HITLOfflineNetworkService.isNetworkToolName(row.toolName)
        let host = HITLOfflineNetworkService.host(fromNetworkToolName: row.toolName)
        let title = isNetwork ? "Network access needed" : "Approval needed"
        let body: String
        if isNetwork, let host {
            body = "The agent wants to reach \(host). Tap to approve or deny."
        } else {
            let preview = truncated(row.argumentsJSON, limit: 160)
            body = preview.isEmpty
                ? "The agent wants to run “\(row.toolName)”. Tap to approve or deny."
                : "“\(row.toolName)” — \(preview)"
        }
        let result = await UserNotificationPoster.post(
            identifier: row.id,
            title: title,
            body: body,
            categoryIdentifier: DerrickNotificationPayload.categoryHITL,
            userInfo: [
                DerrickNotificationPayload.kindKey: DerrickNotificationPayload.kindHITL,
                DerrickNotificationPayload.approvalIDKey: row.id
            ],
            threadIdentifier: row.id
        )
        postingIDs.remove(row.id)
        switch result {
        case .success:
            requestAttentionIfNeeded()
            fputs("[HumanDecision] notification posted id=\(row.id) tool=\(row.toolName) turn=\(row.turnID)\n", stderr)
        case .failure(let error):
            try? await repository.resetHITLNotificationClaim(id: row.id)
            fputs("[HumanDecision] notification post failed id=\(row.id): \(error.localizedDescription)\n", stderr)
        }
    }

    private func postPendingJobResults(repository: DBRepository) async {
        let rows = (try? await repository.fetchJobResultsNeedingNotify()) ?? []
        for row in rows {
            // Stable + unique per result so macOS never replaces/collapses prior banners.
            let key = "derrick.job-result.\(row.id)"
            if postingIDs.contains(key) { continue }
            guard (try? await repository.claimJobResultNotificationPost(id: row.id)) == true else { continue }
            postingIDs.insert(key)

            let shortID = Self.shortID(row.id)
            let scheduled = (try? await repository.fetchJobRunAt(jobID: row.jobID))
                .map { "Scheduled for \($0.formatted(date: .abbreviated, time: .shortened)). " } ?? ""
            let body = scheduled + truncated(row.responseText, limit: 220)
            let result = await UserNotificationPoster.post(
                identifier: key,
                title: "Derrick · Job finished",
                body: body,
                subtitle: "Result \(shortID)",
                userInfo: [
                    DerrickNotificationPayload.kindKey: DerrickNotificationPayload.kindJobResult,
                    DerrickNotificationPayload.jobResultIDKey: row.id
                ],
                threadIdentifier: key,
                timeSensitive: true
            )
            postingIDs.remove(key)
            switch result {
            case .success:
                requestAttentionIfNeeded()
                fputs("[HumanDecision] job result posted id=\(row.id) notify=\(key)\n", stderr)
            case .failure(let error):
                try? await repository.resetJobResultNotificationClaim(id: row.id)
                fputs("[HumanDecision] job result post failed id=\(row.id): \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private static func shortID(_ id: String) -> String {
        String(id.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
    }

    private func resolveHITLFromNotificationTap(approvalID: String) async {
        NSApp.activate(ignoringOtherApps: true)
        guard let row = try? await repository?.fetchPendingHITLApproval(id: approvalID),
              row.status == .pending else {
            fputs("[HumanDecision] tap: no pending row id=\(approvalID)\n", stderr)
            return
        }
        guard let approved = await presentApprovalAlert(for: row) else {
            fputs("[HumanDecision] tap: alert cancelled id=\(approvalID)\n", stderr)
            return
        }
        await resolveHITL(
            approvalID: approvalID,
            approved: approved,
            actor: approved ? "notification-allow" : "notification-deny"
        )
    }

    private func presentApprovalAlert(for row: PendingHITLApprovalRow) async -> Bool? {
        try? await Task.sleep(nanoseconds: 250_000_000)

        let isNetwork = HITLOfflineNetworkService.isNetworkToolName(row.toolName)
        let host = HITLOfflineNetworkService.host(fromNetworkToolName: row.toolName)
        let message: String
        if isNetwork, let host {
            message = "Allow network access to \(host)?"
        } else {
            message = "Allow the agent to run “\(row.toolName)”?"
        }

        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = isNetwork ? "Network access needed" : "Approval needed"
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")

            if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            } else {
                let response = alert.runModal()
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    private func resolveHITL(approvalID: String, approved: Bool, actor: String) async {
        guard let repository else { return }
        guard let row = try? await repository.fetchPendingHITLApproval(id: approvalID),
              row.status == .pending else {
            fputs("[HumanDecision] resolve skip id=\(approvalID)\n", stderr)
            return
        }
        if approved, HITLOfflineNetworkService.isNetworkToolName(row.toolName),
           let host = HITLOfflineNetworkService.host(fromNetworkToolName: row.toolName) {
            await EgressAllowlistService.shared.applyUserNetworkDecision(
                host: host,
                decision: .approvedOnce(actor: actor)
            )
        }
        let status: PendingHITLApprovalStatus = approved ? .approved : .cancelled
        let edited = approved ? row.argumentsJSON : nil
        try? await repository.resolveHITLApproval(
            id: approvalID,
            status: status,
            editedArgumentsJSON: edited,
            actor: actor
        )
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [approvalID])
        fputs("[HumanDecision] \(approved ? "approved" : "denied") id=\(approvalID) turn=\(row.turnID) actor=\(actor)\n", stderr)
    }

    private func presentJobResultFromNotificationTap(id: String) async {
        NSApp.activate(ignoringOtherApps: true)
        guard let repository else { return }
        guard let row = try? await repository.fetchJobResult(id: id) else {
            fputs("[HumanDecision] job result tap: missing row id=\(id)\n", stderr)
            await markJobResultRead(id: id)
            return
        }
        let scheduledAt = try? await repository.fetchJobRunAt(jobID: row.jobID)
        // Small delay so Notification Center finishes dismissing before our modal paints.
        try? await Task.sleep(nanoseconds: 200_000_000)
        JobResultPresenter.shared.present(row: row, scheduledAt: scheduledAt)
        await markJobResultRead(id: id)
    }

    private func markJobResultRead(id: String) async {
        guard let repository else { return }
        try? await repository.markJobResultRead(id: id)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
            "derrick.job-result.\(id)",
            "job-result-\(id)" // legacy identifier
        ])
        fputs("[HumanDecision] job result read id=\(id)\n", stderr)
    }

    private func registerCategories() {
        // No inline actions — user taps the notification body, then sees Allow/Deny in-app.
        let hitl = UNNotificationCategory(
            identifier: DerrickNotificationPayload.categoryHITL,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([hitl])
    }

    private func registerAppActivationObserver() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.pollAndPost()
            }
        }
    }

    private func requestAttentionIfNeeded() {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func shouldNotifyForHITL(_ row: PendingHITLApprovalRow) -> Bool {
        if row.isJobContext { return true }
        // Live chat fallback when UI quit mid-turn.
        return !isUIApplicationProcessRunning()
    }

    private func isUIApplicationProcessRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: DerrickServiceID.ui.rawValue).isEmpty
    }

    private func registerDarwinObserver() {
        guard darwinObserver == nil else { return }
        let observer = Unmanaged.passUnretained(self).toOpaque()
        darwinObserver = observer
        let name = DerrickNotificationSignal.darwinName as CFString
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let service = Unmanaged<DerrickNotificationService>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    await service.pollAndPost()
                }
            },
            name,
            nil,
            .deliverImmediately
        )
    }

    private func unregisterDarwinObserver() {
        guard let observer = darwinObserver else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            CFNotificationName(DerrickNotificationSignal.darwinName as CFString),
            nil
        )
        darwinObserver = nil
    }

    private func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
