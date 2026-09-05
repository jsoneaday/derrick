import Foundation
import DockerRunnerXPC
import Structure

/// UI (and migration callers) → Daemon Mach service.
public actor DaemonClient {
    public static let shared = DaemonClient()

    private var connection: NSXPCConnection?
    private let callTimeoutNanoseconds: UInt64 = 15_000_000_000

    public func health() async throws -> ServiceHealthReport {
        try await withTimeout {
            try await self.healthUnlocked()
        }
    }

    public func bootstrap() async throws -> DerrickDaemonBootstrapResult {
        try await withTimeout {
            try await self.bootstrapUnlocked()
        }
    }

    public func postUserNotification(_ request: UserNotificationRequest) async throws {
        let payload = try DerrickDaemonXPCCodec.encodeNotificationRequest(request)
        let ack = try await withTimeout {
            try await self.postUnlocked(payload)
        }
        guard ack.ok else {
            throw DaemonClientError.rejected(ack.message)
        }
    }

    public func listEgressBlacklist() async throws -> [EgressBlacklistEntryDTO] {
        try await withTimeout {
            try await self.listBlacklistUnlocked()
        }
    }

    public func addEgressBlacklist(pattern: String) async throws {
        let payload = try DerrickDaemonXPCCodec.encodeBlacklistAddRequest(
            EgressBlacklistAddRequest(pattern: pattern)
        )
        let ack = try await withTimeout {
            try await self.addBlacklistUnlocked(payload)
        }
        guard ack.ok else {
            throw DaemonClientError.rejected(ack.message)
        }
    }

    public func removeEgressBlacklist(id: String) async throws {
        let payload = try DerrickDaemonXPCCodec.encodeBlacklistRemoveRequest(
            EgressBlacklistRemoveRequest(id: id)
        )
        let ack = try await withTimeout {
            try await self.removeBlacklistUnlocked(payload)
        }
        guard ack.ok else {
            throw DaemonClientError.rejected(ack.message)
        }
    }

    private func healthUnlocked() async throws -> ServiceHealthReport {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ServiceHealthReport, Error>) in
            let box = OnceResume(cont)
            do {
                nonisolated(unsafe) let proxy = try remoteProxy { box.resume(throwing: $0) }
                proxy.health { data in
                    do {
                        box.resume(returning: try DerrickDaemonXPCCodec.decodeHealth(data as Data))
                    } catch {
                        box.resume(throwing: error)
                    }
                }
            } catch {
                box.resume(throwing: error)
            }
        }
    }

    private func bootstrapUnlocked() async throws -> DerrickDaemonBootstrapResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DerrickDaemonBootstrapResult, Error>) in
            let box = OnceResume(cont)
            do {
                nonisolated(unsafe) let proxy = try remoteProxy { box.resume(throwing: $0) }
                proxy.bootstrap { data in
                    do {
                        box.resume(returning: try DerrickDaemonXPCCodec.decodeBootstrap(data as Data))
                    } catch {
                        box.resume(throwing: error)
                    }
                }
            } catch {
                box.resume(throwing: error)
            }
        }
    }

    private func postUnlocked(_ payload: Data) async throws -> ServiceAckDTO {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ServiceAckDTO, Error>) in
            let box = OnceResume(cont)
            do {
                nonisolated(unsafe) let proxy = try remoteProxy { box.resume(throwing: $0) }
                nonisolated(unsafe) let nsPayload = payload as NSData
                proxy.postUserNotification(requestJSON: nsPayload) { data in
                    do {
                        box.resume(returning: try DerrickDaemonXPCCodec.decodeAck(data as Data))
                    } catch {
                        box.resume(throwing: error)
                    }
                }
            } catch {
                box.resume(throwing: error)
            }
        }
    }

    private func listBlacklistUnlocked() async throws -> [EgressBlacklistEntryDTO] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[EgressBlacklistEntryDTO], Error>) in
            let box = OnceResume(cont)
            do {
                nonisolated(unsafe) let proxy = try remoteProxy { box.resume(throwing: $0) }
                proxy.listEgressBlacklist { data in
                    do {
                        box.resume(returning: try DerrickDaemonXPCCodec.decodeBlacklistList(data as Data).entries)
                    } catch {
                        box.resume(throwing: error)
                    }
                }
            } catch {
                box.resume(throwing: error)
            }
        }
    }

    private func addBlacklistUnlocked(_ payload: Data) async throws -> ServiceAckDTO {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ServiceAckDTO, Error>) in
            let box = OnceResume(cont)
            do {
                nonisolated(unsafe) let proxy = try remoteProxy { box.resume(throwing: $0) }
                nonisolated(unsafe) let nsPayload = payload as NSData
                proxy.addEgressBlacklist(requestJSON: nsPayload) { data in
                    do {
                        box.resume(returning: try DerrickDaemonXPCCodec.decodeAck(data as Data))
                    } catch {
                        box.resume(throwing: error)
                    }
                }
            } catch {
                box.resume(throwing: error)
            }
        }
    }

    private func removeBlacklistUnlocked(_ payload: Data) async throws -> ServiceAckDTO {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ServiceAckDTO, Error>) in
            let box = OnceResume(cont)
            do {
                nonisolated(unsafe) let proxy = try remoteProxy { box.resume(throwing: $0) }
                nonisolated(unsafe) let nsPayload = payload as NSData
                proxy.removeEgressBlacklist(requestJSON: nsPayload) { data in
                    do {
                        box.resume(returning: try DerrickDaemonXPCCodec.decodeAck(data as Data))
                    } catch {
                        box.resume(throwing: error)
                    }
                }
            } catch {
                box.resume(throwing: error)
            }
        }
    }

    private func remoteProxy(
        onError: @escaping @Sendable (Error) -> Void
    ) throws -> DerrickDaemonXPC {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: DerrickServiceID.daemon.machServiceName)
            conn.remoteObjectInterface = NSXPCInterface(with: DerrickDaemonXPC.self)
            do {
                try XPCPeerAuthentication.apply(
                    requirement: XPCPeerAuthentication.requirementString(
                        allowedPeerIdentifiers: [DerrickServiceID.daemon.rawValue]
                    ),
                    to: conn
                )
            } catch {
                fputs("[DaemonClient] peer auth soft-fail: \(error.localizedDescription)\n", stderr)
            }
            conn.invalidationHandler = { [weak self] in
                Task { await self?.clearConnection() }
            }
            conn.interruptionHandler = { [weak self] in
                Task { await self?.clearConnection() }
            }
            conn.resume()
            connection = conn
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            fputs("[DaemonClient] proxy error: \(error.localizedDescription)\n", stderr)
            onError(DaemonClientError.unavailable)
            Task { await self?.clearConnection() }
        }) as? DerrickDaemonXPC else {
            throw DaemonClientError.unavailable
        }
        return proxy
    }

    private func clearConnection() {
        connection?.invalidate()
        connection = nil
    }

    private func withTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeout = callTimeoutNanoseconds
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout)
                throw DaemonClientError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw DaemonClientError.unavailable
            }
            return first
        }
    }
}

/// Ensures an XPC reply / proxy-error / timeout only resumes once.
final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?

    init(_ cont: CheckedContinuation<T, Error>) {
        self.cont = cont
    }

    func resume(returning value: T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}
