import Foundation

/// Guest stdin/stdout boundary checks. Always the bundled JSON Schema via `GuestContract`.
public enum GuestContractValidation: Sendable {
    public static func validateEnvelopeListJSON(_ data: Data) throws {
        try GuestContract.validate(json: data, against: .envelopeList)
    }

    public static func validateHopEventJSON(_ data: Data) throws {
        try GuestContract.validate(json: data, against: .hopEvent)
    }
}
