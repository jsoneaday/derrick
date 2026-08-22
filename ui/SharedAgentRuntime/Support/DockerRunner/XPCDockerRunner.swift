import DockerRunnerXPC
import Foundation
import MCPServer
import ServiceContracts

extension NSData: @unchecked @retroactive Sendable {}

private final class XPCReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Data) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

private final class XPCPeerEndpointReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NSXPCListenerEndpoint, Error>?

    init(_ continuation: CheckedContinuation<NSXPCListenerEndpoint, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: NSXPCListenerEndpoint) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

private final class PrewarmWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume() -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
        return continuation != nil
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
        return continuation != nil
    }
}

private final class PrewarmState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var failure: Error?
    private var waiters: [PrewarmWaiter] = []

    func isCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed && failure == nil
    }

    func failureIfCompleted() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return completed ? failure : nil
    }

    func markCompleted() {
        lock.lock()
        completed = true
        failure = nil
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { _ = $0.resume() }
    }

    func markFailed(_ error: Error) {
        lock.lock()
        completed = true
        failure = error
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { _ = $0.resume(throwing: error) }
    }

    func wait(timeoutNanoseconds: UInt64, timeoutError: Error) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let waiter = PrewarmWaiter(continuation)
            lock.lock()
            if completed {
                let failure = self.failure
                lock.unlock()
                if let failure {
                    _ = waiter.resume(throwing: failure)
                } else {
                    _ = waiter.resume()
                }
                return
            }
            waiters.append(waiter)
            lock.unlock()

            Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                _ = waiter.resume(throwing: timeoutError)
            }
        }
    }
}

private final class XPCAppLogSink: NSObject, DockerHelperLogSinkXPC, @unchecked Sendable {
    func appendLog(message: String) {
        Task { @MainActor in
            debugLog("[XPC helper] \(message)")
        }
    }
}

/// UI-owned XPC bridge and Swift runtime prewarmer.
public final class XPCDockerRunner: @unchecked Sendable {
    public static let shared = XPCDockerRunner()

    private static let serviceName = "derrick.ui.DockerRunnerHelper"
    private static let prewarmWaitCeilingSeconds: UInt64 = 1_200

    private let connection: NSXPCConnection
    private let appLogSink: XPCAppLogSink
    private let prewarmState = PrewarmState()

    public init() {
        let sink = XPCAppLogSink()
        appLogSink = sink

        let conn = NSXPCConnection(serviceName: Self.serviceName)
        conn.remoteObjectInterface = NSXPCInterface(with: DockerProcessRunnerXPC.self)
        conn.exportedInterface = NSXPCInterface(with: DockerHelperLogSinkXPC.self)
        conn.exportedObject = sink
        conn.interruptionHandler = {
            Task { @MainActor in
                debugLog("XPC connection interrupted for service \(Self.serviceName).")
            }
        }
        conn.invalidationHandler = {
            Task { @MainActor in
                debugLog("XPC connection invalidated for service \(Self.serviceName).")
            }
        }

        let requirement = XPCPeerAuthentication.requirementString(for: .appConnectingToHelper)
        do {
            try XPCPeerAuthentication.apply(requirement: requirement, to: conn)
            debugLog("XPC peer code-signing requirement applied: \(requirement)")
        } catch {
            debugLog("XPC peer code-signing requirement failed: \(error.localizedDescription)")
        }

        conn.resume()
        connection = conn
        debugLog("XPCDockerRunner initialized for service \(Self.serviceName).")

        Task {
            await prewarmEnvironment()
        }
    }

    public func waitUntilPrewarmed() async throws {
        if prewarmState.isCompleted() {
            return
        }
        if let failure = prewarmState.failureIfCompleted() {
            throw failure
        }
        let timeout = NSError(
            domain: "XPCDockerRunner",
            code: 504,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Swift runtime setup timed out after \(Self.prewarmWaitCeilingSeconds)s."
            ]
        )
        try await prewarmState.wait(
            timeoutNanoseconds: Self.prewarmWaitCeilingSeconds * 1_000_000_000,
            timeoutError: timeout
        )
    }

    public func fetchPeerListenerEndpoint() async throws -> NSXPCListenerEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            let box = XPCPeerEndpointReplyOnce(continuation)
            Task {
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                } catch {
                    return
                }
                box.resume(
                    throwing: NSError(
                        domain: "XPCDockerRunner",
                        code: 504,
                        userInfo: [NSLocalizedDescriptionKey: "Docker helper peer endpoint timed out."]
                    )
                )
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                box.resume(throwing: error)
            }
            guard let service = proxy as? any DockerProcessRunnerXPC else {
                box.resume(
                    throwing: NSError(
                        domain: "XPCDockerRunner",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "XPC service proxy unavailable."]
                    )
                )
                return
            }
            service.peerListenerEndpoint { endpoint in
                box.resume(returning: endpoint)
            }
        }
    }

    private func prewarmEnvironment() async {
        do {
            await reportBootstrap(phase: .checkingDocker, message: "Checking Docker Desktop…")
            let version = try await runXPCCommand(
                dockerArguments: ["version", "--format", "{{.Server.Version}}"],
                timeoutSeconds: 20
            )
            if version.exitCode != 0 {
                throw NSError(
                    domain: "XPCDockerRunner",
                    code: 503,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            String(decoding: version.stderr, as: UTF8.self)
                    ]
                )
            }
            await reportBootstrap(phase: .preparingImage, message: "Preparing Swift runtime…")
            try await SwiftDockerContainerPool.shared.prewarm(
                image: SwiftScriptPreparer.image,
                executor: makeDockerExecutor()
            )
            prewarmState.markCompleted()
            await reportBootstrap(phase: .verifyingEnvironment, message: "Swift runtime ready.")
        } catch {
            debugLog("Swift runtime prewarming failed: \(error.localizedDescription)")
            prewarmState.markFailed(error)
        }
    }

    private func makeDockerExecutor() -> DockerCLIExecutor {
        { arguments, stdin, timeoutSeconds in
            let response = try await self.runXPCCommand(
                dockerArguments: arguments,
                stdinData: stdin,
                timeoutSeconds: timeoutSeconds
            )
            if let launchError = response.launchError {
                throw NSError(
                    domain: "XPCDockerRunner",
                    code: 503,
                    userInfo: [NSLocalizedDescriptionKey: launchError]
                )
            }
            return DockerCLIResult(
                exitCode: response.exitCode,
                stdout: response.stdout,
                stderr: response.stderr
            )
        }
    }

    private func runXPCCommand(
        dockerArguments: [String],
        stdinData: Data = Data(),
        timeoutSeconds: Int
    ) async throws -> DockerRunResponse {
        let request = DockerHostLaunch.makeRequest(
            dockerArguments: dockerArguments,
            stdinData: stdinData,
            timeoutSeconds: timeoutSeconds,
            environment: DockerHostLaunch.clientProcessEnvironment()
        )
        let requestData = try JSONEncoder().encode(request)
        let timeoutNanoseconds = UInt64(max(timeoutSeconds + 15, 30)) * 1_000_000_000
        nonisolated(unsafe) let payload = requestData as NSData
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            let box = XPCReplyOnce(continuation)
            Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                box.resume(
                    throwing: NSError(
                        domain: "XPCDockerRunner",
                        code: 504,
                        userInfo: [NSLocalizedDescriptionKey: "Docker helper XPC request timed out."]
                    )
                )
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                box.resume(throwing: error)
            }
            guard let service = proxy as? any DockerProcessRunnerXPC else {
                box.resume(
                    throwing: NSError(
                        domain: "XPCDockerRunner",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "XPC service proxy unavailable."]
                    )
                )
                return
            }
            service.runProcess(requestData: payload) { reply in
                box.resume(returning: reply as Data)
            }
        }
        return try JSONDecoder().decode(DockerRunResponse.self, from: responseData)
    }

    private func reportBootstrap(
        phase: AppBootstrapStatus.Phase,
        message: String
    ) async {
        await MainActor.run {
            let status = AppBootstrapStatus.shared
            guard status.isInitializing else { return }
            status.update(phase: phase, message: message)
        }
    }

    deinit {
        connection.invalidate()
    }
}
