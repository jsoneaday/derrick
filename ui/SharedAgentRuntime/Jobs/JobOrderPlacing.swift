import Foundation
import Structure

/// Adapter: JobService XPC.
public struct JobServiceClientOrderPlacer: JobOrderPlacing {
    public var from: DerrickServiceID

    public init(from: DerrickServiceID = .agent) {
        self.from = from
    }

    public func createJob(_ request: CreateJobRequest) async throws -> JobRecord {
        // Avoid ensureUpAndHealth here: long bootstrap can race/hang under a tool call.
        // JobService is already ensure-up'd at UI/agent session start.
        return try await JobServiceClient.shared.createJob(request, from: from)
    }

    public func createSchedule(_ request: CreateScheduleRequest) async throws -> JobScheduleRecord {
        return try await JobServiceClient.shared.createSchedule(request, from: from)
    }
}
