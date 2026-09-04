import Foundation

@objc public protocol ConnectorMessagingXPC {
    func submitConnectorOperation(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
    func pollConnectorOperation(requestJSON: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
}

public enum ConnectorMessagingXPCCodec {
    public static func encodeSubmit(_ request: ConnectorOperationRequest) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodeSubmit(_ data: Data) throws -> ConnectorOperationRequest {
        try JSONDecoder.service.decode(ConnectorOperationRequest.self, from: data)
    }

    public static func encodeAck(_ ack: ConnectorOperationAckDTO) throws -> Data {
        try JSONEncoder.service.encode(ack)
    }

    public static func decodeAck(_ data: Data) throws -> ConnectorOperationAckDTO {
        try JSONDecoder.service.decode(ConnectorOperationAckDTO.self, from: data)
    }

    public static func encodePollRequest(_ request: ConnectorOperationPollRequest) throws -> Data {
        try JSONEncoder.service.encode(request)
    }

    public static func decodePollRequest(_ data: Data) throws -> ConnectorOperationPollRequest {
        try JSONDecoder.service.decode(ConnectorOperationPollRequest.self, from: data)
    }

    public static func encodePollResult(_ result: ConnectorOperationPollResult) throws -> Data {
        try JSONEncoder.service.encode(result)
    }

    public static func decodePollResult(_ data: Data) throws -> ConnectorOperationPollResult {
        try JSONDecoder.service.decode(ConnectorOperationPollResult.self, from: data)
    }
}
