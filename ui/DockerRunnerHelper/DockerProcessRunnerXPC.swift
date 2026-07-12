import Foundation

struct DockerRunRequest: Codable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let stdinData: Data
    let timeoutSeconds: Int
}

struct DockerRunResponse: Codable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
    let timedOut: Bool
    let launchError: String?
    var logs: [String]
}

@objc protocol DockerProcessRunnerXPCProtocol: NSObjectProtocol {
    func runProcess(requestData: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
}

@objc protocol DockerHelperLogSinkXPCProtocol: NSObjectProtocol {
    func appendLog(message: String)
}
