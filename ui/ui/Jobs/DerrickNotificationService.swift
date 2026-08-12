import AppEvents
import AppKit
import DBRepository
import Foundation
import PolicyUserInteraction
import ServiceContracts
import UserNotifications

/// UI presentation for notification taps (job results + HITL Allow/Deny).
///
/// Delivery rules:
/// - Live chat HITL (UI connected): modal via `HITLLiveApprovalHandlers` — no notification.
/// - Offline HITL: posted by derrickd; tap → Allow/Deny alert in the UI.
/// - Job completion: always notified by derrickd; tap → result panel (UI open or closed).
/// - Info/errors during UI session: modal only (`PolicyEventPresenter`), never notifications.
@MainActor
final class DerrickNotificationService {
    static let shared = DerrickNotificationService()

    private var repository: DBRepository?
    private var presentJobResultObserver: DerrickDarwinNotifyObserver?
    private var presentHITLObserver: DerrickDarwinNotifyObserver?
    private let launchEpoch = Date()
    private var sessionReady = false

    private init() {}

    func configure(repository: DBRepository) {
        self.repository = repository
    }

    func prepare() {
        registerPresentJobResultObserver()
        registerPresentHITLObserver()
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
    }

    func stop() {
        unregisterPresentJobResultObserver()
        unregisterPresentHITLObserver()
    }

    func presentHITLApprovalWhenReady(id: String) async {
        for _ in 0..<40 {
            let hasRepository = await ensureRepository() != nil
            if sessionReady || hasRepository {
                await resolveHITLFromNotificationTap(approvalID: id)
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        await resolveHITLFromNotificationTap(approvalID: id)
    }

    private func resolveHITLFromNotificationTap(approvalID: String) async {
        if JobResultPresenter.interactiveSessionActive,
           !JobResultPanelSession.isPanelOnlyLaunch {
            DerrickMainWindowBridge.ensureMainWindow()
        }
        guard await ensureRepository() != nil else { return }
        guard let row = try? await repository?.fetchPendingHITLApproval(id: approvalID),
              row.status == .pending else {
            fputs("[HumanDecision] tap: no pending row id=\(approvalID)\n", stderr)
            return
        }
        guard let outcome = await presentApprovalAlert(for: row) else {
            fputs("[HumanDecision] tap: alert cancelled id=\(approvalID)\n", stderr)
            return
        }
        let actor: String
        if !outcome.approved {
            actor = "notification-deny"
        } else if outcome.always {
            actor = "notification-allow-always"
        } else {
            actor = "notification-allow-once"
        }
        await resolveHITL(
            approvalID: approvalID,
            approved: outcome.approved,
            always: outcome.always,
            actor: actor
        )
        if JobResultPanelSession.isPanelOnlyLaunch {
            JobResultPanelSession.allowsTermination = true
            NSApp.terminate(nil)
        }
    }

    private func presentApprovalAlert(for row: PendingHITLApprovalRow) async -> (approved: Bool, always: Bool)? {
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
            if isNetwork {
                alert.addButton(withTitle: "Always Allow")
                alert.addButton(withTitle: "Allow Once")
                alert.addButton(withTitle: "Deny")
            } else {
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Deny")
            }

            let finish: (NSApplication.ModalResponse) -> Void = { response in
                if isNetwork {
                    switch response {
                    case .alertFirstButtonReturn:
                        continuation.resume(returning: (true, true))
                    case .alertSecondButtonReturn:
                        continuation.resume(returning: (true, false))
                    default:
                        continuation.resume(returning: (false, false))
                    }
                } else {
                    continuation.resume(returning: (response == .alertFirstButtonReturn, false))
                }
            }

            if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                alert.beginSheetModal(for: window, completionHandler: finish)
            } else {
                finish(alert.runModal())
            }
        }
    }

    private func resolveHITL(approvalID: String, approved: Bool, always: Bool = false, actor: String) async {
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
                decision: always
                    ? .approvedPermanently(actor: actor)
                    : .approvedOnce(actor: actor)
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
        fputs("[HumanDecision] \(approved ? "approved" : "denied") id=\(approvalID) turn=\(row.turnID) actor=\(actor)\n", stderr)
    }

    func presentJobResultWhenReady(id: String) async {
        for _ in 0..<40 {
            if sessionReady {
                await presentJobResultFromNotificationTap(id: id)
                return
            }
            if await ensureRepository() != nil {
                await presentJobResultFromNotificationTap(id: id)
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        await presentJobResultFromNotificationTap(id: id)
    }

    private func presentJobResultFromNotificationTap(id: String) async {
        if JobResultPresenter.interactiveSessionActive,
           !JobResultPanelSession.isPanelOnlyLaunch {
            DerrickMainWindowBridge.ensureMainWindow()
        }
        guard await ensureRepository() != nil else { return }
        guard let repository else { return }
        guard let row = try? await repository.fetchJobResult(id: id) else {
            fputs("[HumanDecision] job result tap: missing row id=\(id)\n", stderr)
            await markJobResultRead(id: id)
            return
        }
        let scheduledAt = try? await repository.fetchJobRunAt(jobID: row.jobID)
        let jobFailed = (try? await repository.fetchJobStatus(id: row.jobID)) == JobStatus.failed.rawValue
        let failureDetail: String?
        let failureCode: String?
        if jobFailed, let message = try? await repository.fetchJobFailureMessage(id: row.jobID) {
            failureDetail = JobFailureDisplay.technicalDetail(from: message)
            failureCode = try? await repository.fetchJobErrorCode(id: row.jobID)
        } else {
            failureDetail = nil
            failureCode = nil
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        hideMainWindowsForPanelOnlyIfNeeded()
        JobResultPresenter.shared.present(
            row: row,
            scheduledAt: scheduledAt,
            ephemeralSession: JobResultPresenter.shouldUseEphemeralSession,
            failed: jobFailed,
            failureDetail: failureDetail,
            failureCode: failureCode
        )
        await markJobResultRead(id: id)
    }

    private func hideMainWindowsForPanelOnlyIfNeeded() {
        guard JobResultPresenter.shouldUseEphemeralSession else { return }
        NSApp.setActivationPolicy(.accessory)
        for window in NSApp.windows where !(window is NSPanel) {
            window.orderOut(nil)
        }
    }

    private func markJobResultRead(id: String) async {
        guard let repository else { return }
        try? await repository.markJobResultRead(id: id)
        fputs("[HumanDecision] job result read id=\(id)\n", stderr)
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
            if !JobResultPanelSession.isPanelOnlyLaunch {
                await EgressAllowlistService.shared.configure(repository: repo)
            }
            return repo
        } catch {
            fputs("[HumanDecision] ensureRepository failed: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    private func registerPresentJobResultObserver() {
        guard presentJobResultObserver == nil else { return }
        let observer = DerrickDarwinNotifyObserver(
            darwinName: DerrickJobResultPresentationWake.darwinName
        ) {
            Task { @MainActor in
                if let id = DerrickJobResultPresentationWake.takePendingResultID() {
                    await DerrickNotificationService.shared.presentJobResultWhenReady(id: id)
                }
            }
        }
        presentJobResultObserver = observer
        observer.start()
        if let id = DerrickJobResultPresentationWake.takePendingResultID() {
            Task { @MainActor in
                await self.presentJobResultWhenReady(id: id)
            }
        }
    }

    private func unregisterPresentJobResultObserver() {
        presentJobResultObserver?.stop()
        presentJobResultObserver = nil
    }

    private func registerPresentHITLObserver() {
        guard presentHITLObserver == nil else { return }
        let observer = DerrickDarwinNotifyObserver(
            darwinName: DerrickHITLApprovalPresentationWake.darwinName,
            localName: DerrickHITLApprovalPresentationWake.localNotificationName
        ) {
            Task { @MainActor in
                if let id = DerrickHITLApprovalPresentationWake.takePendingApprovalID() {
                    await DerrickNotificationService.shared.presentHITLApprovalWhenReady(id: id)
                }
            }
        }
        presentHITLObserver = observer
        observer.start()
        if let id = DerrickHITLApprovalPresentationWake.takePendingApprovalID() {
            Task { @MainActor in
                await self.presentHITLApprovalWhenReady(id: id)
            }
        }
    }

    private func unregisterPresentHITLObserver() {
        presentHITLObserver?.stop()
        presentHITLObserver = nil
    }
}
