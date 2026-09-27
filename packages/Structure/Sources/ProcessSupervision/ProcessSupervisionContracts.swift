import Foundation

public struct ProcessLaunchRequest: Codable, Sendable, Hashable {
    public let processID: String
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let timeoutNanoseconds: UInt64?

    public init(
        processID: String,
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        timeoutNanoseconds: UInt64? = nil
    ) {
        self.processID = processID
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.timeoutNanoseconds = timeoutNanoseconds
    }
}

public enum ProcessStatus: String, Codable, Sendable, Hashable {
    case created
    case starting
    case running
    case stopping
    case stopped
    case failed
    case timedOut
}

public struct ProcessHandle: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let launchedAt: Date

    public init(id: String, launchedAt: Date = .now) {
        self.id = id
        self.launchedAt = launchedAt
    }
}

public struct ProcessStatusSnapshot: Codable, Sendable, Hashable {
    public let handle: ProcessHandle
    public let status: ProcessStatus
    public let exitCode: Int32?
    public let detail: String?

    public init(
        handle: ProcessHandle,
        status: ProcessStatus,
        exitCode: Int32? = nil,
        detail: String? = nil
    ) {
        self.handle = handle
        self.status = status
        self.exitCode = exitCode
        self.detail = detail
    }
}

/// Supervises standalone services, guest processes, and helper processes.
public protocol ProcessSupervising: Sendable {
    func launch(_ request: ProcessLaunchRequest) async throws -> ProcessHandle
    func stop(_ handle: ProcessHandle, reason: String?) async
    func cancel(_ handle: ProcessHandle, reason: String?) async
    func status(for handle: ProcessHandle) async -> ProcessStatusSnapshot?
}
