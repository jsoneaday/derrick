import Foundation

/// Request sent from the main app to the XPC service.
struct DockerRunRequest: Codable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let stdinData: Data
    let timeoutSeconds: Int
}

/// Response returned by the XPC service.
struct DockerRunResponse: Codable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
    let timedOut: Bool
    let launchError: String?
    let logs: [String]
}

/// XPC protocol for spawning a process outside the app sandbox.
@objc protocol DockerProcessRunnerXPCProtocol: NSObjectProtocol {
    func runProcess(requestData: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
}

/// XPC protocol used by the helper to stream logs back to the app UI.
@objc protocol DockerHelperLogSinkXPCProtocol: NSObjectProtocol {
    func appendLog(message: String)
}
