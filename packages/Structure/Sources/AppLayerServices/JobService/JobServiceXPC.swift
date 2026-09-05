import Foundation
import CryptoKit

/// XPC interface for JobService (durable jobs + schedule).
@objc public protocol JobServiceXPC {
    func health(withReply reply: @escaping @Sendable (NSData) -> Void)
    func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void)
    /// `authJSON` is signed `peerHandoff` / `fetchJobPeer`. Endpoint travels via NSXPCCoder only.
    /// Used so AgentService (sibling XPC) can call JobService without `serviceName:` launch.
    func peerListenerEndpoint(authJSON: NSData, withReply reply: @escaping @Sendable (NSXPCListenerEndpoint) -> Void)
    /// MCP peer endpoint + signed `installMCPPeerToJob` auth. Reply signed ack.
    /// JobService cannot `serviceName:`-launch MCPService (sibling XPC).
    func setMCPServicePeerEndpoint(
        _ endpoint: NSXPCListenerEndpoint,
        authJSON: NSData,
        withReply reply: @escaping @Sendable (NSData) -> Void
    )
    /// Agent peer endpoint + signed `installAgentPeer` auth. Reply signed ack.
    /// JobService cannot `serviceName:`-launch AgentService (sibling XPC).
    func setAgentServicePeerEndpoint(
        _ endpoint: NSXPCListenerEndpoint,
        authJSON: NSData,
        withReply reply: @escaping @Sendable (NSData) -> Void
    )
    /// Signed `createJob`. Reply `CreateJobResult`.
    func createJob(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Signed cancel. Reply `ServiceAckDTO` signed.
    func cancelJob(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Signed get. Reply `CreateJobResult`-shaped single job.
    func getJob(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Signed list. Reply `ListJobsResult`.
    func listJobs(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Signed schedule CRUD.
    func createSchedule(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    func updateSchedule(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    func setScheduleEnabled(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    func deleteSchedule(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    func getSchedule(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    func listSchedules(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
}

public struct JobServiceBootstrapResult: Codable, Sendable, Hashable {
    public let ok: Bool
    public let databasePath: String?
    public let message: String

    public init(ok: Bool, databasePath: String? = nil, message: String) {
        self.ok = ok
        self.databasePath = databasePath
        self.message = message
    }
}

public enum JobServiceXPCCodec {
    public static func encodeSignedPeerHandoffAuth(
        _ auth: PeerHandoffAuthDTO,
        from: DerrickServiceID,
        to: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        try MCPServiceXPCCodec.encodeSignedPeerHandoffAuth(auth, from: from, to: to, key: key)
    }

    public static func decodeSignedPeerHandoffAuth(
        _ data: Data,
        expectedTo: DerrickServiceID,
        expectedKind: PeerHandoffAuthDTO.Kind,
        key: SymmetricKey? = nil
    ) throws -> PeerHandoffAuthDTO {
        try MCPServiceXPCCodec.decodeSignedPeerHandoffAuth(
            data,
            expectedTo: expectedTo,
            expectedKind: expectedKind,
            key: key
        )
    }

    public static func encodeHealth(_ report: ServiceHealthReport) throws -> Data {
        try JSONEncoder.service.encode(report)
    }

    public static func decodeHealth(_ data: Data) throws -> ServiceHealthReport {
        try JSONDecoder.service.decode(ServiceHealthReport.self, from: data)
    }

    public static func encodeBootstrap(_ result: JobServiceBootstrapResult) throws -> Data {
        try JSONEncoder.service.encode(result)
    }

    public static func decodeBootstrap(_ data: Data) throws -> JobServiceBootstrapResult {
        try JSONDecoder.service.decode(JobServiceBootstrapResult.self, from: data)
    }

    public static func encodeCreateJobRequest(_ request: CreateJobRequest) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodeCreateJobRequest(_ data: Data) throws -> CreateJobRequest {
        try JSONDecoder.service.decode(CreateJobRequest.self, from: data)
    }

    public static func encodeSignedCreateJobRequest(
        _ request: CreateJobRequest,
        from: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            request,
            from: from,
            to: .job,
            type: .createJob,
            principal: request.principal,
            correlationId: request.correlationId,
            key: key
        )
    }

    public static func decodeSignedCreateJobRequest(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> CreateJobRequest {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: CreateJobRequest.self,
            expectedType: .createJob,
            expectedTo: .job,
            key: key
        ).dto
    }

    public static func encodeCreateJobResult(_ result: CreateJobResult) throws -> Data {
        try JSONEncoder.service.encode(result)
    }

    public static func decodeCreateJobResult(_ data: Data) throws -> CreateJobResult {
        try JSONDecoder.service.decode(CreateJobResult.self, from: data)
    }

    public static func encodeSignedCancelJob(
        jobID: String,
        from: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            CancelJobRequest(jobID: jobID),
            from: from,
            to: .job,
            type: .cancelJob,
            principal: .system,
            correlationId: jobID,
            key: key
        )
    }

    public static func decodeSignedCancelJob(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> CancelJobRequest {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: CancelJobRequest.self,
            expectedType: .cancelJob,
            expectedTo: .job,
            key: key
        ).dto
    }

    public static func encodeSignedGetJob(
        jobID: String,
        from: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            GetJobRequest(jobID: jobID),
            from: from,
            to: .job,
            type: .getJob,
            principal: .system,
            correlationId: jobID,
            key: key
        )
    }

    public static func decodeSignedGetJob(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> GetJobRequest {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: GetJobRequest.self,
            expectedType: .getJob,
            expectedTo: .job,
            key: key
        ).dto
    }

    public static func encodeListJobsResult(_ result: ListJobsResult) throws -> Data {
        try JSONEncoder.service.encode(result)
    }

    public static func decodeListJobsResult(_ data: Data) throws -> ListJobsResult {
        try JSONDecoder.service.decode(ListJobsResult.self, from: data)
    }

    public static func encodeSignedListJobs(
        _ request: ListJobsRequest,
        from: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            request,
            from: from,
            to: .job,
            type: .listJobs,
            principal: .system,
            key: key
        )
    }

    public static func decodeSignedListJobs(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> ListJobsRequest {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: ListJobsRequest.self,
            expectedType: .listJobs,
            expectedTo: .job,
            key: key
        ).dto
    }

    public static func encodeSignedAck(
        _ ack: ServiceAckDTO,
        from: DerrickServiceID = .job,
        to: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        try MCPServiceXPCCodec.encodeSignedAck(ack, from: from, to: to, key: key)
    }

    public static func decodeSignedAck(
        _ data: Data,
        expectedTo: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> ServiceAckDTO {
        try MCPServiceXPCCodec.decodeSignedAck(data, expectedTo: expectedTo, key: key)
    }

    // MARK: - Schedules

    public static func encodeScheduleResult(_ result: ScheduleResult) throws -> Data {
        try JSONEncoder.service.encode(result)
    }

    public static func decodeScheduleResult(_ data: Data) throws -> ScheduleResult {
        try JSONDecoder.service.decode(ScheduleResult.self, from: data)
    }

    public static func encodeListSchedulesResult(_ result: ListSchedulesResult) throws -> Data {
        try JSONEncoder.service.encode(result)
    }

    public static func decodeListSchedulesResult(_ data: Data) throws -> ListSchedulesResult {
        try JSONDecoder.service.decode(ListSchedulesResult.self, from: data)
    }

    public static func encodeSignedCreateSchedule(
        _ request: CreateScheduleRequest,
        from: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            request,
            from: from,
            to: .job,
            type: .createSchedule,
            principal: request.principal,
            key: key
        )
    }

    public static func decodeSignedCreateSchedule(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> CreateScheduleRequest {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: CreateScheduleRequest.self,
            expectedType: .createSchedule,
            expectedTo: .job,
            key: key
        ).dto
    }

    public static func encodeSignedUpdateSchedule(
        _ request: UpdateScheduleRequest,
        from: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            request,
            from: from,
            to: .job,
            type: .updateSchedule,
            principal: .system,
            correlationId: request.scheduleID,
            key: key
        )
    }

    public static func decodeSignedUpdateSchedule(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> UpdateScheduleRequest {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: UpdateScheduleRequest.self,
            expectedType: .updateSchedule,
            expectedTo: .job,
            key: key
        ).dto
    }

    public static func encodeSignedSetScheduleEnabled(
        _ request: SetScheduleEnabledRequest,
        from: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            request,
            from: from,
            to: .job,
            type: .updateSchedule,
            principal: .system,
            correlationId: request.scheduleID,
            key: key
        )
    }

    public static func decodeSignedSetScheduleEnabled(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> SetScheduleEnabledRequest {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        // Payload type differs from UpdateScheduleRequest; decode after verify.
        let message = try JSONDecoder.service.decode(ServiceMessage.self, from: data)
        guard message.to == .job else {
            throw ServiceMessageEnvelope.Error.unexpectedRecipient(
                expected: DerrickServiceID.job.rawValue,
                got: message.to.rawValue
            )
        }
        guard ServiceMessageSigning.verify(message, key: key) else {
            throw ServiceMessageEnvelope.Error.invalidSignature
        }
        return try JSONDecoder.service.decode(SetScheduleEnabledRequest.self, from: message.payloadJSON)
    }

    public static func encodeSignedDeleteSchedule(
        scheduleID: String,
        from: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            DeleteScheduleRequest(scheduleID: scheduleID),
            from: from,
            to: .job,
            type: .deleteSchedule,
            principal: .system,
            correlationId: scheduleID,
            key: key
        )
    }

    public static func decodeSignedDeleteSchedule(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> DeleteScheduleRequest {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: DeleteScheduleRequest.self,
            expectedType: .deleteSchedule,
            expectedTo: .job,
            key: key
        ).dto
    }

    public static func encodeSignedGetSchedule(
        scheduleID: String,
        from: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            GetScheduleRequest(scheduleID: scheduleID),
            from: from,
            to: .job,
            type: .listSchedules,
            principal: .system,
            correlationId: scheduleID,
            key: key
        )
    }

    public static func decodeSignedGetSchedule(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> GetScheduleRequest {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        let message = try JSONDecoder.service.decode(ServiceMessage.self, from: data)
        guard message.to == .job else {
            throw ServiceMessageEnvelope.Error.unexpectedRecipient(
                expected: DerrickServiceID.job.rawValue,
                got: message.to.rawValue
            )
        }
        guard ServiceMessageSigning.verify(message, key: key) else {
            throw ServiceMessageEnvelope.Error.invalidSignature
        }
        return try JSONDecoder.service.decode(GetScheduleRequest.self, from: message.payloadJSON)
    }

    public static func encodeSignedListSchedules(
        _ request: ListSchedulesRequest,
        from: DerrickServiceID,
        key: SymmetricKey? = nil
    ) throws -> Data {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.encodeSignedDTO(
            request,
            from: from,
            to: .job,
            type: .listSchedules,
            principal: .system,
            key: key
        )
    }

    public static func decodeSignedListSchedules(
        _ data: Data,
        key: SymmetricKey? = nil
    ) throws -> ListSchedulesRequest {
        let key = try key ?? MessagesSecretKey.symmetricKey()
        return try ServiceMessageEnvelope.decodeSignedDTO(
            data,
            as: ListSchedulesRequest.self,
            expectedType: .listSchedules,
            expectedTo: .job,
            key: key
        ).dto
    }
}
