import DBRepository
import Foundation
import Structure

/// Background ingress for messaging connectors. Runs inside derrickd.
public final class MessagingIngressService: @unchecked Sendable {
    public static let shared = MessagingIngressService()

    private var pollTask: Task<Void, Never>?
    private var darwinObserver: UnsafeMutableRawPointer?
    private let pollIntervalNanoseconds: UInt64 = 4_000_000_000
    private var channelSyncGeneration = 0
    private let channelSyncEveryPolls = 15
    private let pollGate = PollGate()

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
        switch await pollGate.claim() {
        case .skip:
            return
        case .run:
            break
        }
        await runPollPass()
        if await pollGate.finishShouldRunAgain() {
            await pollOnce()
        }
    }

    private func runPollPass() async {
        do {
            let repository = try await DaemonRuntime.shared.sharedRepository()
            let connectors = try await repository.listMessagingConnectors(listeningOnly: true)
            var newRows: [MessagingPersistResult] = []

            if !connectors.isEmpty {
                channelSyncGeneration &+= 1
                let shouldSyncChannels = channelSyncGeneration % channelSyncEveryPolls == 1

                for connector in connectors {
                    do {
                        guard let adapter = MessagingIngressRegistry.adapter(for: connector.pluginID) else {
                            continue
                        }
                        guard adapter.hasCredentials() else { continue }
                        let manifestJSON = try await repository.listLatestPluginFactoryManifests()
                            .first(where: { $0.pluginID == connector.pluginID })?
                            .manifestJSON ?? ""
                        if shouldSyncChannels,
                           PluginFactoryValidationExpectations.supportsSyncThreads(manifestJSON: manifestJSON) {
                            try await adapter.syncThreads(repository: repository)
                        }
                        if PluginFactoryValidationExpectations.supportsPollInbox(manifestJSON: manifestJSON) {
                            let inserted = try await adapter.pollInbox(repository: repository)
                            newRows.append(contentsOf: inserted.filter {
                                $0.inserted && $0.message.direction == .inbound
                            })
                        }
                    } catch {
                        fputs(
                            "[MessagingIngressService] poll failed pluginID=\(connector.pluginID): \(error.localizedDescription)\n",
                            stderr
                        )
                    }
                }
            }

            if !newRows.isEmpty {
                DerrickMessagingInboundSignal.postRefresh()
                await MessagingInboundNotifier.notifyNewInbound(newRows)
                fputs(
                    "[MessagingIngressService] persisted \(newRows.count) inbound message(s)\n",
                    stderr
                )
            }
            try? await repository.releaseUnansweredProfileTokenClaims()
            let unclaimed = (try? await repository.listUnclaimedInboundMessagingMessages()) ?? []
            if !unclaimed.isEmpty {
                await MessagingAgentIngressRouter.processInbound(unclaimed, repository: repository)
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

private actor PollGate {
    enum Claim: Sendable {
        case run
        case skip
    }

    private var running = false
    private var queued = false

    func claim() -> Claim {
        if running {
            queued = true
            return .skip
        }
        running = true
        return .run
    }

    func finishShouldRunAgain() -> Bool {
        running = false
        let again = queued
        queued = false
        return again
    }
}
