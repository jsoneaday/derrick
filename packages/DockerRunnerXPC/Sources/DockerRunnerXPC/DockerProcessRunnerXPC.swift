import Foundation

/// Request sent from the main app to the DockerRunnerHelper XPC service.
public struct DockerRunRequest: Codable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let stdinData: Data
    public let timeoutSeconds: Int

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        stdinData: Data,
        timeoutSeconds: Int
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.stdinData = stdinData
        self.timeoutSeconds = timeoutSeconds
    }
}

/// Response returned by the DockerRunnerHelper XPC service.
public struct DockerRunResponse: Codable, Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public let timedOut: Bool
    public let launchError: String?
    public var logs: [String]

    public init(
        stdout: Data,
        stderr: Data,
        exitCode: Int32,
        timedOut: Bool,
        launchError: String?,
        logs: [String]
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.launchError = launchError
        self.logs = logs
    }
}

/// XPC protocol for spawning a process outside the app sandbox.
@objc public protocol DockerProcessRunnerXPC: NSObjectProtocol {
    func runProcess(requestData: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
}

/// XPC protocol used by the helper to stream logs back to the app UI.
@objc public protocol DockerHelperLogSinkXPC: NSObjectProtocol {
    func appendLog(message: String)
}
