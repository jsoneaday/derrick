import Foundation
import Testing
@testable import ui

@Suite struct AppBootstrapStatusTests {
    @MainActor
    private func freshStatus() -> AppBootstrapStatus {
        let status = AppBootstrapStatus.shared
        status.resetForTesting()
        return status
    }

    @MainActor
    @Test func classifyDockerNotInstalled() {
        let error = NSError(
            domain: "MCPServer",
            code: 503,
            userInfo: [NSLocalizedDescriptionKey: "Docker Desktop is required for script_exec."]
        )
        let result = AppBootstrapStatus.classifyError(error)
        #expect(result.title.contains("Docker"))
        #expect(result.message.lowercased().contains("install"))
    }

    @MainActor
    @Test func classifyDaemonNotRunning() {
        let error = NSError(
            domain: "XPCDockerRunner",
            code: 503,
            userInfo: [NSLocalizedDescriptionKey: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock"]
        )
        let result = AppBootstrapStatus.classifyError(error)
        #expect(result.title == "Docker Desktop Not Running")
        #expect(result.message.lowercased().contains("start docker"))
        #expect(result.recovery == .none)
    }

    @MainActor
    @Test func classifyContainerFailure() {
        let error = NSError(
            domain: "XPCDockerRunner",
            code: 14,
            userInfo: [NSLocalizedDescriptionKey: "Failed to create Swift runtime container: invalid reference format"]
        )
        let result = AppBootstrapStatus.classifyError(error)
        #expect(result.title.contains("Container"))
        #expect(result.message.lowercased().contains("docker"))
        #expect(result.recovery == .none)
    }

    @MainActor
    @Test func classifyDaemonNeedsLoginItemsToggle() {
        let result = AppBootstrapStatus.classifyError(
            JobServiceLoginAgent.AgentError.needsLoginItemsApproval
        )
        #expect(result.title == "Background Service Needs Permission")
        #expect(result.message.lowercased().contains("login items"))
        #expect(result.recovery == .openLoginItems)
    }

    @MainActor
    @Test func classifyDaemonRegisterFailedRetriesInApp() {
        let result = AppBootstrapStatus.classifyError(
            JobServiceLoginAgent.AgentError.registerFailed("SM skipped")
        )
        #expect(result.recovery == .retryDaemon)
        #expect(result.message.lowercased().contains("try again"))
        #expect(!result.message.lowercased().contains("turn derrick off"))
    }

    @MainActor
    @Test func classifyXPCTimeoutDoesNotBlameDockerOrXcode() {
        let error = NSError(
            domain: "AgentServiceClient",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "AgentService XPC call timed out."]
        )
        let result = AppBootstrapStatus.classifyError(error)
        #expect(result.title.contains("Background Service"))
        #expect(!result.message.lowercased().contains("docker"))
        #expect(!result.message.lowercased().contains("xcode"))
        #expect(result.recovery == .none)
    }

    @MainActor
    @Test func classifyCrawlerBuildDumpDoesNotBlockWithRawBuildkit() {
        let error = NSError(
            domain: "MCPServer",
            code: 503,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Docker image build failed for derrick-web-crawler:swift-6.4-v1: #0 building with \"default\" instance using docker driver"
            ]
        )
        let result = AppBootstrapStatus.classifyError(error)
        #expect(result.title.lowercased().contains("crawl"))
        #expect(!result.message.contains("#0 building"))
        #expect(!result.message.contains("derrick-web-crawler:swift-6.4-v1"))
        #expect(result.message.lowercased().contains("chat"))
    }

    @MainActor
    @Test func deferredModalStaysHiddenUntilRevealed() {
        let status = freshStatus()
        #expect(status.beginLoadingSession(deferModal: true))
        #expect(!status.isModalPresented)
        status.revealModalIfStillInitializing()
        #expect(status.isModalPresented)
        status.markReady()
        #expect(!status.isModalPresented)
    }

    @MainActor
    @Test func beginAndReadyToggleModal() {
        let status = freshStatus()
        status.beginLoadingSession()
        #expect(status.isModalPresented || status.phase == .ready || status.phase == .loadingSession)
        if status.phase != .ready {
            #expect(status.isInitializing || status.phase == .loadingSession)
            status.markReady()
        }
        #expect(!status.isModalPresented)
        #expect(status.phase == .ready)
        #expect(status.beginLoadingSession() == false)
        #expect(!status.isModalPresented)
        status.markFailed(title: "x", message: "y")
        #expect(status.phase == .ready)
        #expect(!status.isModalPresented)
    }

    @MainActor
    @Test func runClientBootstrapInvokesBodyWhenAlreadyReady() async {
        let status = freshStatus()
        status.beginLoadingSession()
        status.markReady()
        var bodyInvoked = false
        await status.runClientBootstrap {
            bodyInvoked = true
        }
        #expect(bodyInvoked)
        #expect(status.phase == .ready)
    }

    @MainActor
    @Test func runClientBootstrapInvokesBodyForJoinerAfterReady() async {
        let status = freshStatus()
        status.beginLoadingSession()
        let holdReady = AsyncGate()
        let flightInBody = AsyncGate()

        let flight = Task { @MainActor in
            await status.runClientBootstrap {
                await flightInBody.open()
                await holdReady.wait()
                status.markReady()
            }
        }

        // Ensure the in-flight bootstrap is registered before the joiner attaches.
        await flightInBody.wait()

        var joinerInvoked = false
        let joiner = Task { @MainActor in
            await status.runClientBootstrap {
                joinerInvoked = true
            }
        }

        await holdReady.open()
        await flight.value
        await joiner.value

        #expect(joinerInvoked)
        #expect(status.phase == .ready)
    }

    @MainActor
    @Test func loadingSessionDoesNotOverwriteConnectingHelper() {
        let status = freshStatus()
        #expect(status.beginLoadingSession())
        status.update(phase: .connectingHelper, message: "Connecting to Derrick daemon…")
        status.update(phase: .loadingSession, message: "Opening local database…")
        #expect(status.phase == .connectingHelper)
        #expect(status.statusMessage == "Connecting to Derrick daemon…")
    }

    @MainActor
    @Test func cancelClearsInProgressModal() {
        let status = freshStatus()
        #expect(status.beginLoadingSession() == true)
        #expect(status.isModalPresented)
        status.noteBootstrapCancelled()
        #expect(!status.isModalPresented)
        #expect(status.phase == .idle)
    }
}

/// Test helper: single open/close gate for bootstrap join tests.
private actor AsyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }
}
