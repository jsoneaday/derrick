import Foundation
import CryptoKit

/// Wrap application DTOs in a signed `ServiceMessage` for XPC transport.
public enum ServiceMessageEnvelope {
    public enum Error: Swift.Error, LocalizedError, Equatable {
        case missingSignature
        case invalidSignature
        case unexpectedType(expected: String, got: String)
        case unexpectedRecipient(expected: String, got: String)
        case decodePayload(String)

        public var errorDescription: String? {
            switch self {
            case .missingSignature:
                return "Service message missing HMAC signature."
            case .invalidSignature:
                return "Service message HMAC verification failed."
            case .unexpectedType(let e, let g):
                return "Unexpected service message type (expected \(e), got \(g))."
            case .unexpectedRecipient(let e, let g):
                return "Unexpected service message recipient (expected \(e), got \(g))."
            case .decodePayload(let m):
                return "Failed to decode service message payload: \(m)"
            }
        }
    }

    /// Encode `dto` as signed `ServiceMessage` JSON.
    public static func encodeSignedDTO<T: Encodable>(
        _ dto: T,
        from: DerrickServiceID,
        to: DerrickServiceID,
        type: ServiceMessageType,
        principal: ServicePrincipal,
        correlationId: String? = nil,
        key: SymmetricKey
    ) throws -> Data {
        let payload = try JSONEncoder.service.encode(dto)
        var message = ServiceMessage(
            from: from,
            to: to,
            type: type,
            principal: principal,
            correlationId: correlationId,
            payloadJSON: payload
        )
        ServiceMessageSigning.sign(&message, key: key)
        return try JSONEncoder.service.encode(message)
    }

    /// Decode signed `ServiceMessage` JSON and extract DTO.
    public static func decodeSignedDTO<T: Decodable>(
        _ data: Data,
        as type: T.Type,
        expectedType: ServiceMessageType,
        expectedTo: DerrickServiceID,
        key: SymmetricKey
    ) throws -> (message: ServiceMessage, dto: T) {
        let message = try JSONDecoder.service.decode(ServiceMessage.self, from: data)
        guard message.type == expectedType else {
            throw Error.unexpectedType(expected: expectedType.rawValue, got: message.type.rawValue)
        }
        guard message.to == expectedTo else {
            throw Error.unexpectedRecipient(expected: expectedTo.rawValue, got: message.to.rawValue)
        }
        guard let sig = message.signature, !sig.isEmpty else {
            throw Error.missingSignature
        }
        guard ServiceMessageSigning.verify(message, key: key) else {
            throw Error.invalidSignature
        }
        do {
            let dto = try JSONDecoder.service.decode(T.self, from: message.payloadJSON)
            return (message, dto)
        } catch {
            throw Error.decodePayload(error.localizedDescription)
        }
    }

    /// Convenience: signed control ack (`ServiceAckDTO`).
    public static func encodeAck(
        _ ack: ServiceAckDTO,
        from: DerrickServiceID,
        to: DerrickServiceID,
        type: ServiceMessageType,
        principal: ServicePrincipal = .system,
        correlationId: String? = nil,
        key: SymmetricKey
    ) throws -> Data {
        try encodeSignedDTO(
            ack,
            from: from,
            to: to,
            type: type,
            principal: principal,
            correlationId: correlationId,
            key: key
        )
    }

    public static func decodeAck(
        _ data: Data,
        expectedType: ServiceMessageType,
        expectedTo: DerrickServiceID,
        key: SymmetricKey
    ) throws -> ServiceAckDTO {
        try decodeSignedDTO(
            data,
            as: ServiceAckDTO.self,
            expectedType: expectedType,
            expectedTo: expectedTo,
            key: key
        ).dto
    }
}
