import DBRepository
import Foundation
import ServiceContracts

/// Background ingress for messaging connectors. Runs inside derrickd.
public final class MessagingIngressService: @unchecked Sendable {
    public static let shared = MessagingIngressService()

    private var pollTask: Task<Void, Never>?
    private var darwinObserver: UnsafeMutableRawPointer?
    private let pollIntervalNanoseconds: UInt64 = 4_000_000_000
    private var channelSyncGeneration = 0
    private let channelSyncEveryPolls = 15

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
            let connectors = try await repository.listMessagingConnectors(listeningOnly: true)
            guard !connectors.isEmpty else { return }

            channelSyncGeneration &+= 1
            let shouldSyncChannels = channelSyncGeneration % channelSyncEveryPolls == 1
            var newRows: [MessagingPersistResult] = []

            for connector in connectors {
                guard let adapter = MessagingIngressRegistry.adapter(for: connector.pluginID) else {
                    continue
                }
                guard adapter.hasCredentials() else { continue }
                if shouldSyncChannels {
                    try await adapter.syncThreads(repository: repository)
                }
                let inserted = try await adapter.pollInbox(repository: repository)
                newRows.append(contentsOf: inserted.filter {
                    $0.inserted && $0.message.direction == .inbound
                })
            }

            if !newRows.isEmpty {
                DerrickMessagingInboundSignal.postRefresh()
                fputs(
                    "[MessagingIngressService] persisted \(newRows.count) inbound message(s)\n",
                    stderr
                )
            }
        } catch {
            fputs("[MessagingIngressService] poll failed: \(error.localizedDescription)\n", stderr)
        }
    }

    // MARK: - Darwin observer

    private func registerDarwinObserver() {
        guard darwinObserver == nil else { return }
        let token = Unmanaged.passUnretained(self).toOpaque()
        darwinObserver = token
        let name = DerrickMessagingIngressSignal.darwinName as CFString
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            token,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let service = Unmanaged<MessagingIngressService>.fromOpaque(observer).takeUnretainedValue()
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
            CFNotificationName(DerrickMessagingIngressSignal.darwinName as CFString),
            nil
        )
        darwinObserver = nil
    }
}
