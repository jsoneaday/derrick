import Foundation

/// Host checks that the bundled script_exec JSON still matches its schema and wire schemas.
public enum ScriptExecContractIntegrity: Sendable {
    public static func validateBundledGraph() throws {
        let contractData = try ScriptExecContractStore.resourceData(
            name: ScriptExecContractStore.protocolResource,
            subdirectory: "contracts"
        )
        let contractJSON: [String: Any]
        do {
            contractJSON = try JSONSchema.object(
                from: contractData,
                name: ScriptExecContractStore.protocolResource
            )
        } catch {
            throw ScriptExecContractError.invalidJSON(ScriptExecContractStore.protocolResource)
        }
        try validateAgainstSchema(contractJSON, schema: .scriptExecContract)
        try validateWireSchemaRefs(contractJSON)
        try validateOutputFields(contractJSON)
        try validateReviewChecks(contractJSON)
    }

    private static func validateAgainstSchema(_ instance: Any, schema: GuestContract.Schema) throws {
        do {
            try GuestContract.validate(instance, against: schema)
        } catch let error as GuestContractError {
            throw ScriptExecContractError.integrityFailed(error.localizedDescription)
        }
    }

    private static func validateWireSchemaRefs(_ contract: [String: Any]) throws {
        guard let io = contract["io"] as? [String: Any] else { return }
        for key in ["stdin_schema", "stdout_schema", "guest_runtime_schema"] {
            guard let fileName = io[key] as? String,
                  GuestContract.Schema(rawValue: fileName) != nil else {
                throw ScriptExecContractError.integrityFailed(
                    "script-exec-contract.json io.\(key) must reference a bundled guest schema."
                )
            }
        }
    }

    private static func validateOutputFields(_ contract: [String: Any]) throws {
        let envelope = try GuestContract.loadSchemaObject(.envelopeList)
        guard let properties = (envelope["items"] as? [String: Any])?["properties"] as? [String: Any] else {
            throw ScriptExecContractError.integrityFailed(
                "envelope-list.schema.json is missing items.properties."
            )
        }
        let envelopeKeys = Set(properties.keys)
        guard let output = contract["output"] as? [String: Any],
              let fields = output["fields"] as? [String: Any] else {
            return
        }
        let missing = Set(fields.keys).subtracting(envelopeKeys)
        if !missing.isEmpty {
            throw ScriptExecContractError.integrityFailed(
                "script-exec-contract.json output.fields references unknown envelope fields: \(missing.sorted().joined(separator: ", "))."
            )
        }
    }

    private static func validateReviewChecks(_ contract: [String: Any]) throws {
        guard let review = contract["review"] as? [String: Any],
              let checks = review["checks"] as? [[String: Any]] else {
            return
        }
        var seenIDs: Set<String> = []
        var seenOrders: Set<Int> = []
        for check in checks {
            guard let id = check["id"] as? String,
                  let order = check["order"] as? Int else {
                throw ScriptExecContractError.integrityFailed(
                    "script-exec-contract.json review.checks entries require id and order."
                )
            }
            if seenIDs.contains(id) {
                throw ScriptExecContractError.integrityFailed(
                    "script-exec-contract.json review.checks has duplicate id \(id)."
                )
            }
            if seenOrders.contains(order) {
                throw ScriptExecContractError.integrityFailed(
                    "script-exec-contract.json review.checks has duplicate order \(order)."
                )
            }
            seenIDs.insert(id)
            seenOrders.insert(order)
        }
    }
}
