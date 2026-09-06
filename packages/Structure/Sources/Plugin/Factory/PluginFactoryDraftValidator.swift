import Foundation

/// Deterministic draft gates run before the safety reviewer. Failures are builder-correctable:
/// `PluginFactorySession` feeds findings back to the builder model and retries.
public enum PluginFactoryDraftValidator: Sendable {
    public static func validateStructure(
        draft: PluginFactoryDraft,
        manifest: AgentPluginManifest
    ) throws {
        var findings: [String] = []
        let script: PluginFactoryTestScript
        do {
            script = try PluginFactoryTestScript.parse(draft.testInput)
        } catch let error as PluginFactoryError {
            switch error {
            case .invalidSource(let message):
                findings.append(message)
            default:
                findings.append(error.localizedDescription)
            }
            throw failure(findings)
        }

        if manifest.isConnector {
            findings.append(contentsOf: connectorStructureFindings(
                draft: draft,
                manifest: manifest,
                script: script
            ))
        } else if isEmptyTestInput(draft.testInput) {
            findings.append("test_input_json must not be empty.")
        }

        if !findings.isEmpty {
            throw failure(findings)
        }
    }

    public static func validateDirectTest(
        draft: PluginFactoryDraft,
        manifest: AgentPluginManifest,
        hopRun: PluginFactoryHopTestRun
    ) throws {
        var findings: [String] = []
        let result = hopRun.final

        guard result.exitCode == 0 else {
            findings.append("Direct test must exit 0.")
            throw failure(findings)
        }

        let envelopes: [PluginEnvelope]
        do {
            envelopes = try terminalEnvelopes(from: hopRun)
        } catch {
            findings.append(
                "Direct test output must be a valid envelope array. \(error.localizedDescription)"
            )
            throw failure(findings)
        }

        if envelopes.isEmpty {
            findings.append(
                "Direct test must reach a terminal result.emit envelope after replaying test_input_json hops."
            )
        }

        if manifest.isConnector {
            findings.append(contentsOf: connectorDirectTestFindings(
                draft: draft,
                manifest: manifest,
                hopRun: hopRun,
                terminalEnvelopes: envelopes
            ))
        }

        if !findings.isEmpty {
            throw failure(findings)
        }
    }

    private static func connectorStructureFindings(
        draft: PluginFactoryDraft,
        manifest: AgentPluginManifest,
        script: PluginFactoryTestScript
    ) -> [String] {
        var findings: [String] = []
        let manifestOps = PluginFactoryValidationExpectations.messagingOps(fromManifestJSON: draft.manifestJSON)
        let requiredOps = resolvedRequiredOps(manifestOps: manifestOps, userGoal: draft.userGoal)

        if manifestOps.isEmpty {
            findings.append(
                "Connector manifest must declare extensions.app.derrick.messaging_ops for every implemented operation."
            )
        }

        if script.hops.count < 2 {
            findings.append(
                "Connector test_input_json must use a hops array with an initial messaging hop and an http_results hop."
            )
        }

        if script.hops.first?.params?["messaging_op"]?.stringValue?.isEmpty != false {
            findings.append("Connector test_input_json must set params.messaging_op on the first hop.")
        }

        let fixtureCount = script.hops.reduce(0) { $0 + ($1.httpResults?.count ?? 0) }
        if fixtureCount == 0 {
            findings.append("Connector test_input_json must include http_results fixtures for vendor HTTP replay.")
        }

        let testedOps = messagingOpsExercised(in: script)
        for op in requiredOps where !testedOps.contains(op) {
            findings.append(
                "test_input_json must include a hop with params.messaging_op \(op) matching the declared scope."
            )
        }

        for op in manifestOps where !requiredOps.isEmpty && !requiredOps.contains(op) {
            findings.append("Manifest declares messaging_op \(op) outside the user goal scope.")
        }

        for op in requiredOps where !manifestOps.contains(op) {
            findings.append("Manifest messaging_ops must declare \(op) required by the user goal.")
        }

        let document = try? ConnectorContractStore.loadProtocol()
        if let document,
           let scopeID = PluginFactoryScopeHints.scopeID(from: draft.userGoal),
           let spec = try? document.scope(id: scopeID),
           spec.includeReplyPoll {
            let hasReplyPoll = script.hops.contains { hop in
                hop.params?["messaging_op"]?.stringValue == ConnectorMessagingOperation.pollInbox.rawValue
                    && hopHasReplyParent(hop)
            }
            if !hasReplyPoll {
                findings.append(
                    "Full sync test_input_json must include a poll_inbox hop with parent_vendor_message_id (reply thread)."
                )
            }
        }

        findings.append(contentsOf: fixtureIntegrityFindings(in: script))
        findings.append(contentsOf: hopParamsSchemaFindings(in: script))
        findings.append(contentsOf: hopKindFindings(script: script, document: document))
        let knownOps = Set(PluginFactoryValidationExpectations.knownMessagingOps)
        for op in messagingOpsExercised(in: script) where !knownOps.contains(op) {
            findings.append("params.messaging_op \(op) is not a connector protocol op.")
        }
        return findings
    }

    private static func hopKindFindings(
        script: PluginFactoryTestScript,
        document: ConnectorProtocolDocument?
    ) -> [String] {
        guard let document else { return [] }
        var findings: [String] = []
        for hop in script.hops {
            guard hop.kind != .httpResults else { continue }
            let op = hop.params?["messaging_op"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let spec = document.ops[op] else { continue }
            if hop.kind.rawValue != spec.kind {
                findings.append("Op \(op) hop kind must be \(spec.kind).")
            }
        }
        return findings
    }

    private static func hopHasReplyParent(_ hop: PluginHopEvent) -> Bool {
        let parent = hop.params?["parent_vendor_message_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let threadTS = hop.params?["thread_ts"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (parent?.isEmpty == false) || (threadTS?.isEmpty == false)
    }

    private static func connectorDirectTestFindings(
        draft: PluginFactoryDraft,
        manifest: AgentPluginManifest,
        hopRun: PluginFactoryHopTestRun,
        terminalEnvelopes: [PluginEnvelope]
    ) -> [String] {
        var findings: [String] = []
        let script = (try? PluginFactoryTestScript.parse(draft.testInput))
        let manifestOps = PluginFactoryValidationExpectations.messagingOps(fromManifestJSON: draft.manifestJSON)
        let requiredOps = resolvedRequiredOps(manifestOps: manifestOps, userGoal: draft.userGoal)

        if let script {
            let emittedRequestIDs = httpRequestIDs(from: hopRun.hopResults)
            let fixtureRequestIDs = fixtureRequestIDs(in: script)
            for requestID in emittedRequestIDs where !fixtureRequestIDs.contains(requestID) {
                findings.append(
                    "test_input_json http_results must include a fixture for emitted request_id \(requestID)."
                )
            }
            findings.append(
                contentsOf: forbiddenVendorCallFindings(
                    script: script,
                    hopRun: hopRun,
                    userGoal: draft.userGoal
                )
            )
        }

        let document = try? ConnectorContractStore.loadProtocol()
        let requireSentMessage = document?.ops[ConnectorMessagingOperation.sendMessage.rawValue]?
            .success.requiresSentMessage ?? true
        let requirePollMessages = document?.rules.directTestPollRequiresNonEmptyMessages ?? true
        let requireThreads = document?.rules.directTestThreadsRequiresNonEmpty ?? true

        if requiredOps.contains(ConnectorMessagingOperation.sendMessage.rawValue),
           requireSentMessage,
           !terminalEnvelopes.contains(where: { $0.verb == .resultEmit && $0.payload["sent_message"] != nil }) {
            findings.append(
                "send_message direct test must emit result.emit with sent_message when that op is in scope."
            )
        }

        if requiredOps.contains(ConnectorMessagingOperation.pollInbox.rawValue), requirePollMessages {
            let hasMessages = terminalEnvelopes.contains { terminal in
                terminal.payload["messages"].flatMap { value -> Bool? in
                    if case .array(let items) = value { return !items.isEmpty }
                    return nil
                } ?? false
            }
            if !hasMessages {
                findings.append(
                    "poll_inbox direct test must emit result.emit with a non-empty messages array when that op is in scope."
                )
            }
        }

        if requiredOps.contains(ConnectorMessagingOperation.syncThreads.rawValue), requireThreads {
            let hasThreads = terminalEnvelopes.contains { terminal in
                terminal.payload["threads"].flatMap { value -> Bool? in
                    if case .array(let items) = value { return !items.isEmpty }
                    return nil
                } ?? false
            }
            if !hasThreads {
                findings.append(
                    "sync_threads direct test must emit result.emit with a non-empty threads array when that op is in scope."
                )
            }
        }

        findings.append(contentsOf: emitShapeFindings(in: terminalEnvelopes))

        _ = manifest
        return findings
    }

    private static func hopParamsSchemaFindings(in script: PluginFactoryTestScript) -> [String] {
        var findings: [String] = []
        for hop in script.hops {
            guard let params = hop.params else { continue }
            do {
                try GuestContract.validate(
                    PluginJSON.object(params).untypedJSON,
                    against: .connectorParams
                )
            } catch {
                findings.append(error.localizedDescription)
            }
        }
        return findings
    }

    private static func emitShapeFindings(in terminals: [PluginEnvelope]) -> [String] {
        var findings: [String] = []
        for terminal in terminals where terminal.verb == .resultEmit {
            do {
                try GuestContract.validate(
                    PluginJSON.object(terminal.payload).untypedJSON,
                    against: .connectorResultEmit
                )
            } catch {
                findings.append(error.localizedDescription)
            }
        }
        return findings
    }

    private static func resolvedRequiredOps(manifestOps: [String], userGoal: String?) -> [String] {
        let fromGoal = PluginFactoryValidationExpectations.requiredMessagingOps(from: userGoal)
        if !fromGoal.isEmpty { return fromGoal.sorted() }
        return manifestOps.sorted()
    }

    private static func messagingOpsExercised(in script: PluginFactoryTestScript) -> Set<String> {
        Set(
            script.hops.compactMap { hop in
                hop.params?["messaging_op"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        )
    }

    private static func fixtureIntegrityFindings(in script: PluginFactoryTestScript) -> [String] {
        var findings: [String] = []
        for hop in script.hops {
            guard let results = hop.httpResults else { continue }
            var seen: Set<String> = []
            for response in results {
                let id = response.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else {
                    findings.append("Each http_results fixture must include a non-empty request_id.")
                    continue
                }
                if seen.contains(id) {
                    findings.append(
                        "http_results fixtures must not repeat request_id \(id); de-duplicate before lookup."
                    )
                }
                seen.insert(id)
            }
        }
        return findings
    }

    private static func forbiddenVendorCallFindings(
        script: PluginFactoryTestScript,
        hopRun: PluginFactoryHopTestRun,
        userGoal: String?
    ) -> [String] {
        guard let document = try? ConnectorContractStore.loadProtocol() else { return [] }
        let vendor = try? ConnectorContractStore.loadVendor(
            ConnectorContractStore.vendorName(fromUserGoal: userGoal) ?? ""
        )
        let scopeID = PluginFactoryScopeHints.scopeID(from: userGoal)
        let scope = scopeID.flatMap { try? document.scope(id: $0) }
        var findings: [String] = []
        for index in script.hops.indices {
            guard index < hopRun.hopResults.count else { break }
            let hop = script.hops[index]
            let paired = index + 1 < script.hops.count ? script.hops[index + 1] : nil
            let op = resolvedMessagingOp(hop: hop, paired: paired)
            guard let spec = document.ops[op] else { continue }
            var forbidden = spec.mustNotCall
            if op == ConnectorMessagingOperation.pollInbox.rawValue {
                if hopHasReplyParent(hop) || paired.map(hopHasReplyParent) == true {
                    forbidden.append(contentsOf: spec.whenNoParent?.mayCall ?? [])
                } else {
                    forbidden.append(contentsOf: spec.whenParent?.mayCall ?? [])
                    forbidden.append(contentsOf: scope?.pollMustNotCall ?? [])
                }
            }
            let needles = ConnectorContractStore.urlNeedles(forCallIDs: forbidden, vendor: vendor)
            guard let envelopes = try? PluginEnvelopeList.decode(hopRun.hopResults[index].stdout) else {
                continue
            }
            for envelope in envelopes where envelope.verb == .httpRequest {
                let url = envelope.payload["url"]?.stringValue ?? ""
                for needle in needles where !needle.isEmpty && url.localizedCaseInsensitiveContains(needle) {
                    findings.append(
                        "Op \(op) must not call \(needle)."
                    )
                }
            }
        }
        return findings
    }

    private static func resolvedMessagingOp(hop: PluginHopEvent, paired: PluginHopEvent?) -> String {
        let own = hop.params?["messaging_op"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !own.isEmpty { return own }
        let next = paired?.params?["messaging_op"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return next
    }

    private static func httpRequestIDs(from hopResults: [PluginFactoryExecutionResult]) -> Set<String> {
        var ids: Set<String> = []
        for hop in hopResults {
            guard let envelopes = try? PluginEnvelopeList.decode(hop.stdout) else { continue }
            for envelope in envelopes where envelope.verb == .httpRequest {
                if let id = envelope.payload["request_id"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !id.isEmpty {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    private static func fixtureRequestIDs(in script: PluginFactoryTestScript) -> Set<String> {
        var ids: Set<String> = []
        for hop in script.hops {
            for response in hop.httpResults ?? [] {
                let id = response.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty { ids.insert(id) }
            }
        }
        return ids
    }

    private static func isEmptyTestInput(_ data: Data) -> Bool {
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "{}"
    }

    private static func failure(_ findings: [String]) -> PluginFactoryError {
        .draftValidationFailed(findings: findings)
    }

    private static func terminalEnvelopes(from hopRun: PluginFactoryHopTestRun) throws -> [PluginEnvelope] {
        var terminals: [PluginEnvelope] = []
        for hop in hopRun.hopResults {
            let envelopes = try PluginEnvelopeList.decode(hop.stdout)
            terminals.append(contentsOf: envelopes.filter { $0.verb.classification == .terminal })
        }
        return terminals
    }
}
