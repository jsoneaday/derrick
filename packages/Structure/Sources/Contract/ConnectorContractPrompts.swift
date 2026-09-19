import Foundation

/// Renders the bundled connector protocol for factory, builder, and reviewer prompts.
public enum ConnectorContractPrompts: Sendable {
    public static func hostContract() -> String {
        dumpOrUnavailable(scopeID: nil, vendorName: nil, preamble: """
        Connector protocol (canonical JSON). Implement only these ops. Do not add requirements \
        that are not in this document. Vendor HTTP bindings follow when a vendor profile is supplied.
        """)
    }

    public static func builderGuide(vendorName: String? = nil) -> String {
        dumpOrUnavailable(scopeID: nil, vendorName: vendorName, preamble: """
        Connector builder rules come only from this protocol JSON. Do not invent extra vendor APIs. \
        Direct tests must include http_results fixtures for every emitted request_id. Direct tests for \
        poll_inbox must include a non-empty messages fixture. Runtime poll_inbox with vendor success \
        and messages: [] is success.
        """)
    }

    public static func builderGuide(forUserGoal userGoal: String?) -> String {
        builderGuide(vendorName: ConnectorContractStore.vendorName(fromUserGoal: userGoal))
    }

    public static func reviewerGuide(vendorName: String? = nil) -> String {
        dumpOrUnavailable(scopeID: nil, vendorName: vendorName, preamble: """
        Review connectors against this protocol JSON only. If a rule is not in the JSON, do not require it. \
        Do not reject sync_threads for omitting conversation.history or conversation.replies. \
        Do not reject emitting messages: [] when the vendor reported success. \
        Reject empty messages as success only when the vendor reported failure.
        """)
    }

    public static func reviewerGuide(forUserGoal userGoal: String?) -> String {
        reviewerGuide(vendorName: ConnectorContractStore.vendorName(fromUserGoal: userGoal))
    }

    public static func factoryGoal(
        vendorLabel: String,
        scope: PluginFactoryCreateInput.ConnectorScope,
        vendor: PluginFactoryCreateInput.ConnectorVendor?,
        crawlSummary: String?,
        inboxAPISummary: String? = nil,
        agentPluginSpecSummary: String? = nil,
        agentPluginSpecSourceURL: String? = nil,
        reference: String?,
        includeVendorBindings: Bool = true
    ) throws -> String {
        let document = try ConnectorContractStore.loadProtocol()
        let scopeID = scope.rawValue
        let scopeSpec = try document.scope(id: scopeID)
        var parts: [String] = [
            "Create an Agent Plugin messaging connector for \(vendorLabel).",
            "Scope id: \(scopeID)",
            "Implement messaging_ops: \(scopeSpec.ops.map { "\"\($0)\"" }.joined(separator: ", ")).",
        ]
        if let agentPluginSpecSummary, !agentPluginSpecSummary.isEmpty {
            parts.append(
                AgentPluginSpec.forcedPromptBlock(
                    summary: agentPluginSpecSummary,
                    sourceURL: agentPluginSpecSourceURL
                )
            )
        }
        parts.append(
            try dump(
                scopeID: scopeID,
                vendorName: includeVendorBindings ? vendor?.rawValue : nil,
                preamble: "Obey this protocol JSON. Do not add ops or vendor calls outside it. Vendor HTTP bindings are host facts; use those URLs."
            )
        )
        parts.append(
            """
            test_input_json must include a hops array with http_results fixtures that exercise every messaging_op you implement \
            (\(scopeSpec.ops.joined(separator: ", "))) through to result.emit.
            """
        )
        parts.append(
            PluginFactoryCreateInput.defaultDescription(
                vendor: vendor,
                customVendorName: vendor == .custom ? vendorLabel : nil,
                scope: scope
            )
        )
        if let reference, !reference.isEmpty {
            parts.append(reference)
        }
        if let crawlSummary, !crawlSummary.isEmpty {
            let clipped = String(crawlSummary.prefix(2_000))
            parts.append(
                """
                Reference these crawled vendor API notes only to fill may_call HTTP details that the host vendor bindings do not cover. \
                If crawl notes disagree with the host vendor JSON, keep the host vendor JSON.
                They cannot add ops:
                \(clipped)
                """
            )
        }
        if let inboxAPISummary, !inboxAPISummary.isEmpty {
            let clipped = String(inboxAPISummary.prefix(2_000))
            parts.append(
                """
                Reference these crawled notes on how this vendor lists conversations and loads threads. \
                Fill HTTP details only. They cannot add ops:
                \(clipped)
                """
            )
        }
        parts.append(
            """
            After listing conversations, emit ui.present in the same envelope list as result.emit. \
            Use element ids from the host UI catalog summary only. Prefer asking for the messaging_inbox example tree, then adapt. \
            selection=conversations means the host opens the first conversation immediately — do not request an empty screen. \
            Do not add error or timeout widgets; the host shows those only after a later command fails. \
            Keep http hops for vendor calls. The host records ui.present and finishes that hop — do not wait for another guest run after present. \
            skill_files must include at least one skills/<name>/SKILL.md (Agent Skills required).
            """
        )
        return parts.joined(separator: "\n\n")
    }

    public static func dump(
        scopeID: String?,
        vendorName: String?,
        preamble: String
    ) throws -> String {
        let document = try ConnectorContractStore.loadProtocol()
        let vendor = try vendorName.flatMap { try ConnectorContractStore.loadVendor($0) }
        var lines: [String] = [preamble, "", "--- connector-contract.json ---"]
        lines.append(try ConnectorContractStore.loadProtocolText())
        if let scopeID {
            let scope = try document.scope(id: scopeID)
            lines.append("")
            lines.append("Active scope \(scopeID): ops=\(scope.ops.joined(separator: ",")) include_reply_poll=\(scope.includeReplyPoll) test_pagination=\(scope.testPagination)")
            if !scope.pollMustNotCall.isEmpty {
                lines.append("poll_must_not_call=\(scope.pollMustNotCall.joined(separator: ","))")
            }
        }
        lines.append("")
        lines.append("--- \(GuestContract.Schema.hopEvent.rawValue) ---")
        lines.append(try GuestContract.loadSchemaText(.hopEvent))
        lines.append("")
        lines.append("--- \(GuestContract.Schema.envelopeList.rawValue) ---")
        lines.append(try GuestContract.loadSchemaText(.envelopeList))
        lines.append("")
        lines.append("--- \(GuestContract.Schema.connectorParams.rawValue) ---")
        lines.append(try GuestContract.loadSchemaText(.connectorParams))
        lines.append("")
        lines.append("--- \(GuestContract.Schema.connectorResultEmit.rawValue) ---")
        lines.append(try GuestContract.loadSchemaText(.connectorResultEmit))
        lines.append("")
        lines.append("--- host UI catalog (summary) ---")
        lines.append(try HostUIDisclosure.catalogSummary())
        lines.append("")
        lines.append("Ask the host for HostUIDisclosure.elementSchema(id:) or exampleTree(named:) before inventing config. Do not expect a full host-ui-library.json dump.")
        if let vendor, let vendorJSON = try ConnectorContractStore.loadVendorText(vendor.vendor) {
            lines.append("")
            lines.append("--- vendor \(vendor.vendor) ---")
            lines.append(vendorJSON)
        }
        return lines.joined(separator: "\n")
    }

    private static func dumpOrUnavailable(
        scopeID: String?,
        vendorName: String?,
        preamble: String
    ) -> String {
        (try? dump(scopeID: scopeID, vendorName: vendorName, preamble: preamble))
            ?? "Connector protocol JSON failed to load."
    }
}
