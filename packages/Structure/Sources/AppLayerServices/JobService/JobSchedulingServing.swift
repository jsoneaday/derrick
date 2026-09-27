import Foundation

public enum JobSchedulingStatus: String, Codable, Sendable, Hashable {
    case stopped
    case starting
    case running
    case degraded
    case failed
}

public struct JobSchedulingSnapshot: Codable, Sendable, Hashable {
    public let status: JobSchedulingStatus
    public let observedAt: Date
    public let claimedScheduleCount: Int
    public let claimedJobCount: Int
    public let detail: String?

    public init(
        status: JobSchedulingStatus,
        observedAt: Date = .now,
        claimedScheduleCount: Int = 0,
        claimedJobCount: Int = 0,
        detail: String? = nil
    ) {
        self.status = status
        self.observedAt = observedAt
        self.claimedScheduleCount = claimedScheduleCount
        self.claimedJobCount = claimedJobCount
        self.detail = detail
    }
}

/// Contract for the JobSchedulingModule hosted by the current job runtime.
public protocol JobSchedulingServing: Sendable {
    func start() async throws
    func stop() async
    func recoverInterruptedWork() async throws -> Int
    func runOnce(at date: Date) async throws -> JobSchedulingSnapshot
    func status() async -> JobSchedulingSnapshot
}
