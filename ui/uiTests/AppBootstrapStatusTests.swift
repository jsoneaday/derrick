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
        status.beginLoadingSession()
        #expect(status.isModalPresented)
        #expect(status.isInitializing)
        status.markReady()
        #expect(!status.isModalPresented)
        #expect(status.phase == .ready)
    }
}
