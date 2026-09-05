import Foundation

/// Structural validation for guest I/O at container boundaries.
public enum GuestContractValidation: Sendable {
    public static func validateEnvelopeListJSON(_ data: Data) throws {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw GuestContractError.validationFailed(
                "Guest stdout must be a JSON array of envelope objects."
            )
        }
        let allowed = Set(try GuestContract.officialEnvelopeVerbs())
        for (index, element) in array.enumerated() {
            guard let object = element as? [String: Any] else {
                throw GuestContractError.validationFailed(
                    "Envelope at index \(index) must be a JSON object."
                )
            }
            let verb = (object["verb"] as? String) ?? (object["type"] as? String)
            guard let verb, !verb.isEmpty else {
                throw GuestContractError.validationFailed(
                    "Envelope at index \(index) is missing verb."
                )
            }
            guard allowed.contains(verb) else {
                throw GuestContractError.validationFailed(
                    "Envelope at index \(index) uses unknown verb '\(verb)'."
                )
            }
        }
    }

    public static func validateHopEventJSON(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GuestContractError.validationFailed("Guest stdin must be a JSON object.")
        }
        guard let kind = object["kind"] as? String, !kind.isEmpty else {
            throw GuestContractError.validationFailed("Guest stdin is missing kind.")
        }
        let allowed = Set(try GuestContract.officialHopEventKinds())
        guard allowed.contains(kind) else {
            throw GuestContractError.validationFailed("Guest stdin uses unknown kind '\(kind)'.")
        }
        if let results = object["http_results"] {
            guard results is [Any] else {
                throw GuestContractError.validationFailed("http_results must be an array.")
            }
        }
        if let params = object["params"] {
            guard params is [String: Any] else {
                throw GuestContractError.validationFailed("params must be an object.")
            }
        }
    }
}

enum SchemaEnumLoader {
    static func stringEnum(
        from data: Data,
        property: String,
        arrayPath: [String] = []
    ) throws -> [String] {
        guard var node = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GuestContractError.invalidJSON
        }
        for key in arrayPath {
            guard let next = node[key] as? [String: Any] else {
                throw GuestContractError.invalidJSON
            }
            node = next
        }
        guard let properties = node["properties"] as? [String: Any],
              let field = properties[property] as? [String: Any],
              let values = field["enum"] as? [String] else {
            throw GuestContractError.invalidJSON
        }
        return values
    }
}
