import Foundation

/// Host checks that the bundled connector JSON still matches its schemas and Swift ops.
public enum ConnectorContractIntegrity: Sendable {
    public static func validateBundledGraph() throws {
        let contractData = try ConnectorContractStore.resourceData(
            name: "connector-contract.json",
            subdirectory: "contracts"
        )
        let contractJSON: [String: Any]
        do {
            contractJSON = try JSONSchema.object(
                from: contractData,
                name: ConnectorContractStore.protocolResource
            )
        } catch {
            throw ConnectorContractError.invalidJSON(ConnectorContractStore.protocolResource)
        }
        try validateAgainstSchema(contractJSON, schema: .connectorContract)

        let paramsSchema = try GuestContract.loadSchemaObject(.connectorParams)
        let emitSchema = try GuestContract.loadSchemaObject(.connectorResultEmit)
        try validateParamsCoverOps(contract: contractJSON, paramsSchema: paramsSchema)
        try validateEmitCoversOps(contract: contractJSON, emitSchema: emitSchema)
        try validateHostEnums(contract: contractJSON, paramsSchema: paramsSchema)

        let slackData = try ConnectorContractStore.resourceData(
            name: "slack.json",
            subdirectory: "contracts/vendors"
        )
        let slackJSON: [String: Any]
        do {
            slackJSON = try JSONSchema.object(from: slackData, name: "vendors/slack.json")
        } catch {
            throw ConnectorContractError.invalidJSON("vendors/slack.json")
        }
        try validateAgainstSchema(slackJSON, schema: .connectorVendor)
        try validateVendorCallIDs(contract: contractJSON, vendor: slackJSON)
    }

    private static func validateAgainstSchema(_ instance: Any, schema: GuestContract.Schema) throws {
        do {
            try GuestContract.validate(instance, against: schema)
        } catch let error as GuestContractError {
            throw ConnectorContractError.integrityFailed(error.localizedDescription)
        }
    }

    public static func messagingOpIDs(fromParamsSchema schema: [String: Any]? = nil) throws -> [String] {
        let params = try schema ?? GuestContract.loadSchemaObject(.connectorParams)
        guard let properties = params["properties"] as? [String: Any],
              let messagingOp = properties["messaging_op"] as? [String: Any],
              let values = messagingOp["enum"] as? [String],
              !values.isEmpty else {
            throw ConnectorContractError.integrityFailed(
                "connector-params.schema.json must enumerate messaging_op values."
            )
        }
        return values
    }

    public static func requiredKeys(inEmitField field: String) throws -> [String] {
        let emit = try GuestContract.loadSchemaObject(.connectorResultEmit)
        guard let properties = emit["properties"] as? [String: Any],
              let node = properties[field] as? [String: Any] else {
            throw ConnectorContractError.integrityFailed(
                "connector-result-emit.schema.json is missing \(field)."
            )
        }
        if field == "sent_message" {
            return node["required"] as? [String] ?? []
        }
        guard let items = node["items"] as? [String: Any],
              let required = items["required"] as? [String] else {
            throw ConnectorContractError.integrityFailed(
                "connector-result-emit.schema.json \(field) items must declare required keys."
            )
        }
        return required
    }

    private static func validateParamsCoverOps(
        contract: [String: Any],
        paramsSchema: [String: Any]
    ) throws {
        let allowed = try messagingOpIDs(fromParamsSchema: paramsSchema)
        let properties = (paramsSchema["properties"] as? [String: Any]) ?? [:]
        let paramNames = Set(properties.keys)
        guard let ops = contract["ops"] as? [String: Any] else { return }
        for (opID, raw) in ops {
            guard allowed.contains(opID) else {
                throw ConnectorContractError.integrityFailed(
                    "Op \(opID) is missing from connector-params.schema.json messaging_op enum."
                )
            }
            guard let spec = raw as? [String: Any],
                  let params = spec["params"] as? [String] else { continue }
            for param in params where !paramNames.contains(param) {
                throw ConnectorContractError.integrityFailed(
                    "Op \(opID) param \(param) is missing from connector-params.schema.json."
                )
            }
        }
    }

    private static func validateEmitCoversOps(
        contract: [String: Any],
        emitSchema: [String: Any]
    ) throws {
        let emitFields = Set(((emitSchema["properties"] as? [String: Any]) ?? [:]).keys)
        guard let ops = contract["ops"] as? [String: Any] else { return }
        for (opID, raw) in ops {
            guard let spec = raw as? [String: Any],
                  let emit = spec["emit"] as? String else { continue }
            guard emitFields.contains(emit) else {
                throw ConnectorContractError.integrityFailed(
                    "Op \(opID) emit \(emit) is missing from connector-result-emit.schema.json."
                )
            }
        }
    }

    private static func validateHostEnums(
        contract: [String: Any],
        paramsSchema: [String: Any]
    ) throws {
        let opIDs = Set(((contract["ops"] as? [String: Any]) ?? [:]).keys)
        let hostOps = Set(ConnectorMessagingOperation.allCases.map(\.rawValue))
        guard opIDs == hostOps else {
            throw ConnectorContractError.integrityFailed(
                "connector-contract.json ops must match ConnectorMessagingOperation."
            )
        }
        let paramOps = Set(try messagingOpIDs(fromParamsSchema: paramsSchema))
        guard paramOps == hostOps else {
            throw ConnectorContractError.integrityFailed(
                "connector-params.schema.json messaging_op enum must match ConnectorMessagingOperation."
            )
        }
        let scopeIDs = Set(((contract["scopes"] as? [String: Any]) ?? [:]).keys)
        let hostScopes = Set(PluginFactoryCreateInput.ConnectorScope.allCases.map(\.rawValue))
        guard scopeIDs == hostScopes else {
            throw ConnectorContractError.integrityFailed(
                "connector-contract.json scopes must match ConnectorScope."
            )
        }
    }

    private static func validateVendorCallIDs(
        contract: [String: Any],
        vendor: [String: Any]
    ) throws {
        let calls = Set(((vendor["calls"] as? [String: Any]) ?? [:]).keys)
        var referenced: Set<String> = []
        func collect(_ values: Any?) {
            if let ids = values as? [String] {
                referenced.formUnion(ids)
            }
        }
        guard let ops = contract["ops"] as? [String: Any] else { return }
        for raw in ops.values {
            guard let spec = raw as? [String: Any] else { continue }
            collect(spec["may_call"])
            collect(spec["must_not_call"])
            if let whenNoParent = spec["when_no_parent"] as? [String: Any] {
                collect(whenNoParent["may_call"])
            }
            if let whenParent = spec["when_parent"] as? [String: Any] {
                collect(whenParent["may_call"])
            }
        }
        if let scopes = contract["scopes"] as? [String: Any] {
            for raw in scopes.values {
                guard let spec = raw as? [String: Any] else { continue }
                collect(spec["poll_must_not_call"])
            }
        }
        let missing = referenced.subtracting(calls)
        if !missing.isEmpty {
            throw ConnectorContractError.integrityFailed(
                "Slack vendor profile is missing call ids: \(missing.sorted().joined(separator: ", "))."
            )
        }
    }
}
