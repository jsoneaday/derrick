import Foundation

@objc public protocol WorkflowRuntimeXPC {
    func startWorkflow(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    func pollWorkflowUpdate(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    func cancelWorkflow(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
}

public enum WorkflowRuntimeXPCCodec {
    public static func encodeStart(_ request: WorkflowStartRequest) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodeStart(_ data: Data) throws -> WorkflowStartRequest {
        try JSONDecoder.service.decode(WorkflowStartRequest.self, from: data)
    }

    public static func encodeHandle(_ handle: WorkflowHandleDTO) throws -> Data {
        try JSONEncoder.service.encode(handle)
    }

    public static func decodeHandle(_ data: Data) throws -> WorkflowHandleDTO {
        try JSONDecoder.service.decode(WorkflowHandleDTO.self, from: data)
    }

    public static func encodePollRequest(_ request: WorkflowPollRequest) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodePollRequest(_ data: Data) throws -> WorkflowPollRequest {
        try JSONDecoder.service.decode(WorkflowPollRequest.self, from: data)
    }

    public static func encodePollResult(_ result: WorkflowPollResultDTO) throws -> Data {
        try JSONEncoder.service.encode(result)
    }

    public static func decodePollResult(_ data: Data) throws -> WorkflowPollResultDTO {
        try JSONDecoder.service.decode(WorkflowPollResultDTO.self, from: data)
    }

    public static func encodeCancel(_ request: WorkflowCancelRequest) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodeCancel(_ data: Data) throws -> WorkflowCancelRequest {
        try JSONDecoder.service.decode(WorkflowCancelRequest.self, from: data)
    }
}
