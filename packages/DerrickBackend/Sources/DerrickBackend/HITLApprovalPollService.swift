import DBRepository
import Foundation
import ServiceContracts

/// Polls SQLite for pending HITL approvals and posts banners via the Daemon.
public final class HITLApprovalPollService: @unchecked Sendable {
    public static let shared = HITLApprovalPollService()

    private var pollTask: Task<Void, Never>?
    private var darwinObserver: UnsafeMutableRawPointer?
    private let pollIntervalNanoseconds: UInt64 = 2_000_000_000

    private init() {}

    public func start() {
        registerDarwinObserver()
        guard pollTask == nil else { return }
        pollTask = Task {
            await self.pollOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
                await self.pollOnce()
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        unregisterDarwinObserver()
    }

    public func pollOnce() async {
        do {
            let repository = try await DaemonRuntime.shared.sharedRepository()
            await HITLApprovalNotifier.pollAndPost(repository: repository)
        } catch {
            fputs("[HITLApprovalPollService] poll failed: \(error.localizedDescription)\n", stderr)
        }
    }

    // MARK: - Darwin observer

    private func registerDarwinObserver() {
        guard darwinObserver == nil else { return }
        let token = Unmanaged.passUnretained(self).toOpaque()
        darwinObserver = token
        let name = DerrickHITLNotificationSignal.darwinName as CFString
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            token,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let service = Unmanaged<HITLApprovalPollService>.fromOpaque(observer).takeUnretainedValue()
                Task { await service.pollOnce() }
            },
            name,
            nil,
            .deliverImmediately
        )
    }

    private func unregisterDarwinObserver() {
        guard let token = darwinObserver else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            token,
            CFNotificationName(DerrickHITLNotificationSignal.darwinName as CFString),
            nil
        )
        darwinObserver = nil
    }
}
