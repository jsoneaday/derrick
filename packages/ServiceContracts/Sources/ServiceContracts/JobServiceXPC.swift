import Foundation
import CryptoKit

/// XPC interface for JobService (durable jobs + schedule).
@objc public protocol JobServiceXPC {
    func health(withReply reply: @escaping @Sendable (NSData) -> Void)
    func bootstrap(withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Signed `createJob` envelope. Reply `CreateJobResult` JSON (unsigned body for now).
    func createJob(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Signed cancel. Reply `ServiceAckDTO` signed.
    func cancelJob(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Signed get. Reply `CreateJobResult`-shaped single job.
    func getJob(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    /// Signed list. Reply `ListJobsResult`.
    func listJobs(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
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
}
