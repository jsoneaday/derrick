import Foundation
import DockerRunnerXPC
import ServiceContracts

/// Client for JobService (create/cancel/list jobs + ensure-up).
public final class JobServiceClient: @unchecked Sendable {
    public static let shared = JobServiceClient()

    private let serviceName = DerrickServiceID.job.xpcServiceName
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var isReady = false
    private let callTimeoutNanoseconds: UInt64 = 15_000_000_000

    private init() {}

    public func ensureUpAndHealth(retries: Int = 3) async throws -> ServiceHealthReport {
        var lastError: Error?
        for attempt in 0..<max(1, retries) {
            do {
                nonisolated(unsafe) let proxy = try remoteProxy()
                let boot: JobServiceBootstrapResult = try await invoke(timeout: callTimeoutNanoseconds) {
                    try await withCheckedThrowingContinuation { cont in
                        proxy.bootstrap { data in
                            do {
                                cont.resume(returning: try JobServiceXPCCodec.decodeBootstrap(data as Data))
                            } catch {
                                cont.resume(throwing: error)
                            }
                        }
                    }
                }
                await MainActor.run {
                    debugLog(
                        "JobService bootstrap: ok=\(boot.ok) path=\(boot.databasePath ?? "?") msg=\(boot.message)"
                    )
                }
                guard boot.ok else {
                    throw JobServiceClientError.bootstrapFailed(boot.message)
                }
                let report: ServiceHealthReport = try await invoke(timeout: callTimeoutNanoseconds) {
                    try await withCheckedThrowingContinuation { cont in
                        proxy.health { data in
                            do {
                                cont.resume(returning: try JobServiceXPCCodec.decodeHealth(data as Data))
                            } catch {
                                cont.resume(throwing: error)
                            }
                        }
                    }
                }
                await MainActor.run {
                    debugLog(
                        "JobService health: status=\(report.status.rawValue) pid=\(report.pid) detail=\(report.detail ?? "")"
                    )
                }
                markReady()
                return report
            } catch {
                lastError = error
                await MainActor.run {
                    debugLog("JobService ensure-up attempt \(attempt + 1) failed: \(error.localizedDescription)")
                }
                invalidate()
                try? await Task.sleep(nanoseconds: UInt64(100_000_000 * (attempt + 1)))
            }
        }
        throw lastError ?? JobServiceClientError.unavailable
    }

    public func createJob(_ request: CreateJobRequest, from: DerrickServiceID = .ui) async throws -> JobRecord {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedCreateJobRequest(request, from: from) as NSData
        let result: CreateJobResult = try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { cont in
                proxy.createJob(requestJSON: payload) { data in
                    do {
                        cont.resume(returning: try JobServiceXPCCodec.decodeCreateJobResult(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        guard result.ok, let job = result.job else {
            throw JobServiceClientError.requestFailed(result.message)
        }
        return job
    }

    public func cancelJob(jobID: String, from: DerrickServiceID = .ui) async throws {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedCancelJob(jobID: jobID, from: from) as NSData
        try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                proxy.cancelJob(requestJSON: payload) { data in
                    do {
                        let ack = try JobServiceXPCCodec.decodeSignedAck(data as Data, expectedTo: from)
                        if ack.ok { cont.resume() }
                        else { cont.resume(throwing: JobServiceClientError.requestFailed(ack.message)) }
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    public func getJob(jobID: String, from: DerrickServiceID = .ui) async throws -> JobRecord {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedGetJob(jobID: jobID, from: from) as NSData
        let result: CreateJobResult = try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { cont in
                proxy.getJob(requestJSON: payload) { data in
                    do {
                        cont.resume(returning: try JobServiceXPCCodec.decodeCreateJobResult(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        guard result.ok, let job = result.job else {
            throw JobServiceClientError.requestFailed(result.message)
        }
        return job
    }

    public func listJobs(_ request: ListJobsRequest = ListJobsRequest(), from: DerrickServiceID = .ui) async throws -> [JobRecord] {
        nonisolated(unsafe) let proxy = try remoteProxy()
        let payload = try JobServiceXPCCodec.encodeSignedListJobs(request, from: from) as NSData
        let result: ListJobsResult = try await invoke(timeout: callTimeoutNanoseconds) {
            try await withCheckedThrowingContinuation { cont in
                proxy.listJobs(requestJSON: payload) { data in
                    do {
                        cont.resume(returning: try JobServiceXPCCodec.decodeListJobsResult(data as Data))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
        guard result.ok else {
            throw JobServiceClientError.requestFailed(result.message)
        }
        return result.jobs
    }

    // MARK: - Connection

    private func markReady() {
        lock.lock()
        isReady = true
        lock.unlock()
    }

    private func remoteProxy() throws -> JobServiceXPC {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let conn = NSXPCConnection(serviceName: serviceName)
            conn.remoteObjectInterface = NSXPCInterface(with: JobServiceXPC.self)
            do {
                try XPCPeerAuthentication.apply(
                    requirement: XPCPeerAuthentication.requirementString(
                        allowedPeerIdentifiers: [DerrickServiceID.job.rawValue]
                    ),
                    to: conn
                )
            } catch {
                fputs("[JobServiceClient] code-sign soft-fail: \(error.localizedDescription)\n", stderr)
            }
            conn.interruptionHandler = { [weak self] in self?.invalidate() }
            conn.invalidationHandler = { [weak self] in self?.invalidate() }
            conn.resume()
            connection = conn
            fputs("[JobServiceClient] connected serviceName=\(serviceName)\n", stderr)
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            fputs("[JobServiceClient] proxy error: \(error.localizedDescription)\n", stderr)
            self?.invalidate()
        }) as? JobServiceXPC else {
            throw JobServiceClientError.unavailable
        }
        return proxy
    }

    private func invalidate() {
        lock.lock()
        connection?.invalidate()
        connection = nil
        isReady = false
        lock.unlock()
    }

    private func invoke<T: Sendable>(
        timeout nanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw JobServiceClientError.timeout
            }
            guard let first = try await group.next() else { throw JobServiceClientError.timeout }
            group.cancelAll()
            return first
        }
    }
}

public enum JobServiceClientError: Error, LocalizedError {
    case unavailable
    case bootstrapFailed(String)
    case requestFailed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "JobService is unavailable."
        case .bootstrapFailed(let m): return "JobService bootstrap failed: \(m)"
        case .requestFailed(let m): return "JobService request failed: \(m)"
        case .timeout: return "JobService XPC call timed out."
        }
    }
}
