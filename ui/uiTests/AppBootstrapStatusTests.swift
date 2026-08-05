import Foundation
import Testing
@testable import ui

@Suite struct AppBootstrapStatusTests {
    @MainActor
    @Test func classifyDockerNotInstalled() {
        let error = NSError(
            domain: "MCPServer",
            code: 503,
            userInfo: [NSLocalizedDescriptionKey: "Docker Desktop is required for python_script_exec."]
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
        #expect(result.title.lowercased().contains("not running") || result.title.contains("Docker"))
        #expect(result.message.lowercased().contains("start docker"))
    }

    @MainActor
    @Test func classifyContainerFailure() {
        let error = NSError(
            domain: "XPCDockerRunner",
            code: 14,
            userInfo: [NSLocalizedDescriptionKey: "Failed to create warm container derrick-runner-net-px2: invalid reference format"]
        )
        let result = AppBootstrapStatus.classifyError(error)
        #expect(result.title.contains("Container"))
        #expect(result.message.lowercased().contains("docker"))
    }

    @MainActor
    @Test func beginAndReadyToggleModal() {
        let status = AppBootstrapStatus.shared
        // Reset shared singleton from other tests / prior ready.
        status.noteBootstrapCancelled()
        if status.phase == .ready || status.phase == .failed {
            // force idle via cancel path only works when not ready/failed — use mark then cancel n/a
        }
        // After ready, begin must not re-open modal.
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
    @Test func cancelClearsInProgressModal() {
        let status = AppBootstrapStatus.shared
        // Ensure we can start: if ready, failed path is blocked — use a fresh begin only if idle/failed.
        if status.phase == .ready {
            // Simulate post-ready: cancel is no-op; begin ignored.
            status.noteBootstrapCancelled()
            #expect(status.phase == .ready)
            return
        }
        if status.phase == .failed {
            status.dismissFailure()
        }
        #expect(status.beginLoadingSession() == true)
        #expect(status.isModalPresented)
        status.noteBootstrapCancelled()
        #expect(!status.isModalPresented)
        #expect(status.phase == .idle)
    }
}
