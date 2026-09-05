import Foundation

// MARK: - Recurrence

/// How a schedule repeats after each fire.
public enum JobRecurrenceKind: String, Codable, Sendable, Hashable {
    /// Fire once at `nextFireAt`, then disable.
    case once
    /// Fire when due, then set `nextFireAt = fireTime + intervalSeconds`.
    case interval
}

public struct JobRecurrence: Codable, Sendable, Hashable {
    public let kind: JobRecurrenceKind
    /// Required when `kind == .interval` (minimum 60 seconds).
    public let intervalSeconds: Int?

    public init(kind: JobRecurrenceKind, intervalSeconds: Int? = nil) {
        self.kind = kind
        self.intervalSeconds = intervalSeconds
    }

    public static let once = JobRecurrence(kind: .once, intervalSeconds: nil)

    public static func every(seconds: Int) -> JobRecurrence {
        JobRecurrence(kind: .interval, intervalSeconds: max(60, seconds))
    }

    public static func every(hours: Int) -> JobRecurrence {
        .every(seconds: max(1, hours) * 3600)
    }

    public static func every(days: Int) -> JobRecurrence {
        .every(seconds: max(1, days) * 86_400)
    }
}

// MARK: - Schedule record

/// Template that the scheduler uses to spawn job **runs**.
public struct JobScheduleRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var enabled: Bool
    public let principal: ServicePrincipal
    public let source: JobSource
    public var recurrence: JobRecurrence
    /// Step template (same shape as create-job steps).
    public var steps: [CreateJobStepSpec]
    public var nextFireAt: Date?
    public var lastFiredAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        enabled: Bool = true,
        principal: ServicePrincipal,
        source: JobSource,
        recurrence: JobRecurrence,
        steps: [CreateJobStepSpec],
        nextFireAt: Date? = nil,
        lastFiredAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.principal = principal
        self.source = source
        self.recurrence = recurrence
        self.steps = steps
        self.nextFireAt = nextFireAt
        self.lastFiredAt = lastFiredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - API

public struct CreateScheduleRequest: Codable, Sendable, Hashable {
    public let name: String
    public let principal: ServicePrincipal
    public let source: JobSource
    public let recurrence: JobRecurrence
    public let steps: [CreateJobStepSpec]
    /// First fire time. If nil and enabled, defaults to now (ASAP).
    public let nextFireAt: Date?
    public let enabled: Bool

    public init(
        name: String,
        principal: ServicePrincipal,
        source: JobSource,
        recurrence: JobRecurrence,
        steps: [CreateJobStepSpec],
        nextFireAt: Date? = nil,
        enabled: Bool = true
    ) {
        self.name = name
        self.principal = principal
        self.source = source
        self.recurrence = recurrence
        self.steps = steps
        self.nextFireAt = nextFireAt
        self.enabled = enabled
    }
}

public struct UpdateScheduleRequest: Codable, Sendable, Hashable {
    public let scheduleID: String
    public let name: String?
    public let enabled: Bool?
    public let recurrence: JobRecurrence?
    public let steps: [CreateJobStepSpec]?
    public let nextFireAt: Date?

    public init(
        scheduleID: String,
        name: String? = nil,
        enabled: Bool? = nil,
        recurrence: JobRecurrence? = nil,
        steps: [CreateJobStepSpec]? = nil,
        nextFireAt: Date? = nil
    ) {
        self.scheduleID = scheduleID
        self.name = name
        self.enabled = enabled
        self.recurrence = recurrence
        self.steps = steps
        self.nextFireAt = nextFireAt
    }
}

public struct SetScheduleEnabledRequest: Codable, Sendable, Hashable {
    public let scheduleID: String
    public let enabled: Bool

    public init(scheduleID: String, enabled: Bool) {
        self.scheduleID = scheduleID
        self.enabled = enabled
    }
}

public struct DeleteScheduleRequest: Codable, Sendable, Hashable {
    public let scheduleID: String

    public init(scheduleID: String) {
        self.scheduleID = scheduleID
    }
}

public struct GetScheduleRequest: Codable, Sendable, Hashable {
    public let scheduleID: String

    public init(scheduleID: String) {
        self.scheduleID = scheduleID
    }
}

public struct ListSchedulesRequest: Codable, Sendable, Hashable {
    public let limit: Int
    public let enabledOnly: Bool

    public init(limit: Int = 100, enabledOnly: Bool = false) {
        self.limit = limit
        self.enabledOnly = enabledOnly
    }
}

public struct ScheduleResult: Codable, Sendable, Hashable {
    public let ok: Bool
    public let schedule: JobScheduleRecord?
    public let message: String

    public init(ok: Bool, schedule: JobScheduleRecord? = nil, message: String = "ok") {
        self.ok = ok
        self.schedule = schedule
        self.message = message
    }
}

public struct ListSchedulesResult: Codable, Sendable, Hashable {
    public let ok: Bool
    public let schedules: [JobScheduleRecord]
    public let message: String

    public init(ok: Bool, schedules: [JobScheduleRecord] = [], message: String = "ok") {
        self.ok = ok
        self.schedules = schedules
        self.message = message
    }
}

// MARK: - Next fire computation

public enum JobScheduleTiming {
    /// Advance after a successful fire at `firedAt`.
    public static func nextFireDate(
        after firedAt: Date,
        recurrence: JobRecurrence
    ) -> Date? {
        switch recurrence.kind {
        case .once:
            return nil
        case .interval:
            let seconds = max(60, recurrence.intervalSeconds ?? 3600)
            return firedAt.addingTimeInterval(TimeInterval(seconds))
        }
    }
}
