import Foundation

/// Persistence rows for JobService (domain mapping to AppLayerServices/JobService wire types).
public struct JobRow: Sendable, Hashable {
    public let id: String
    public var status: String
    public let principalJSON: String
    public let source: String
    public let correlationID: String?
    public let scheduleID: String?
    public var runAt: Date?
    public let createdAt: Date
    public var updatedAt: Date
    public var errorMessage: String?
    /// Stable code (e.g. JobFailureReason.rawValue).
    public var errorCode: String?
    /// Non-terminal note (e.g. started late after sleep).
    public var statusDetail: String?

    public init(
        id: String,
        status: String,
        principalJSON: String,
        source: String,
        correlationID: String?,
        scheduleID: String? = nil,
        runAt: Date?,
        createdAt: Date,
        updatedAt: Date,
        errorMessage: String?,
        errorCode: String? = nil,
        statusDetail: String? = nil
    ) {
        self.id = id
        self.status = status
        self.principalJSON = principalJSON
        self.source = source
        self.correlationID = correlationID
        self.scheduleID = scheduleID
        self.runAt = runAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
        self.errorCode = errorCode
        self.statusDetail = statusDetail
    }
}

public struct JobScheduleRow: Sendable, Hashable {
    public let id: String
    public var name: String
    public var enabled: Bool
    public let principalJSON: String
    public let source: String
    public var recurrenceKind: String
    public var intervalSeconds: Int?
    public var stepsJSON: String
    public var nextFireAt: Date?
    public var lastFiredAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        enabled: Bool,
        principalJSON: String,
        source: String,
        recurrenceKind: String,
        intervalSeconds: Int?,
        stepsJSON: String,
        nextFireAt: Date?,
        lastFiredAt: Date?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.principalJSON = principalJSON
        self.source = source
        self.recurrenceKind = recurrenceKind
        self.intervalSeconds = intervalSeconds
        self.stepsJSON = stepsJSON
        self.nextFireAt = nextFireAt
        self.lastFiredAt = lastFiredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct JobStepRow: Sendable, Hashable {
    public let id: String
    public let jobID: String
    public let index: Int
    public let kind: String
    public var status: String
    public let payloadJSON: String
    public var resultJSON: String?
    public var errorMessage: String?
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: String,
        jobID: String,
        index: Int,
        kind: String,
        status: String,
        payloadJSON: String,
        resultJSON: String? = nil,
        errorMessage: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.index = index
        self.kind = kind
        self.status = status
        self.payloadJSON = payloadJSON
        self.resultJSON = resultJSON
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}
