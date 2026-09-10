import Foundation
import Structure
import Testing

@Suite struct ConnectorContractTests {
    @Test func protocolJSONLoadsAndMatchesHostOps() throws {
        let document = try ConnectorContractStore.loadProtocol()
        #expect(document.version == 1)
        let opIDs = Set(document.ops.keys)
        let hostIDs = Set(ConnectorMessagingOperation.allCases.map(\.rawValue))
        #expect(opIDs == hostIDs)
        #expect(try document.scope(id: "full_sync").includeReplyPoll)
        #expect(try document.scope(id: "full_sync").testPagination == "follow_cursor")
        #expect(document.scopes["send_only"] == nil)
        #expect(document.scopes["send_and_receive"] == nil)
        #expect(document.ops["sync_threads"]?.mustNotCall.contains("conversation.history") == true)
        #expect(document.ops["sync_threads"]?.success.emptyCollectionOK == true)
        #expect(document.ops["send_message"]?.success.requiresSentMessage == true)
        #expect(document.rules.runtimeEmptyMessagesOKIfVendorOK)
        #expect(document.rules.directTestPollRequiresNonEmptyMessages)
        #expect(document.rules.directTestThreadsRequiresNonEmpty)
    }

    @Test func slackVendorProfileBindsCallIDs() throws {
        let slack = try ConnectorContractStore.loadVendor("slack")
        #expect(slack?.calls["conversation.list"]?.method == "conversations.list")
        #expect(slack?.calls["message.send"]?.method == "chat.postMessage")
        #expect(try ConnectorContractStore.loadVendor("telegram") == nil)
    }

    @Test func fingerprintMatchesGeneratedFile() throws {
        #expect(try ConnectorContractStore.computeFingerprint() == ConnectorContractFingerprint.sha256)
        #expect(ConnectorContractFingerprint.sourceFiles == ConnectorContractStore.fingerprintSources)
    }

    @Test func bundledContractSatisfiesItsSchemas() throws {
        try ConnectorContractIntegrity.validateBundledGraph()
    }

    @Test func factoryGoalDumpsCanonicalJSONFiles() throws {
        let goal = slackFullSyncGoal()
        let protocolText = try ConnectorContractStore.loadProtocolText()
        let paramsText = try GuestContract.loadSchemaText(.connectorParams)
        let emitText = try GuestContract.loadSchemaText(.connectorResultEmit)
        let hopText = try GuestContract.loadSchemaText(.hopEvent)
        let envelopeText = try GuestContract.loadSchemaText(.envelopeList)
        let slackText = try #require(try ConnectorContractStore.loadVendorText("slack"))
        #expect(goal.contains(protocolText))
        #expect(goal.contains(paramsText))
        #expect(goal.contains(emitText))
        #expect(goal.contains(hopText))
        #expect(goal.contains(envelopeText))
        #expect(goal.contains(slackText))
        #expect(goal.contains("--- \(GuestContract.Schema.connectorParams.rawValue) ---"))
        #expect(goal.contains("--- \(GuestContract.Schema.connectorResultEmit.rawValue) ---"))
        #expect(goal.contains("--- \(GuestContract.Schema.hopEvent.rawValue) ---"))
        #expect(goal.contains("--- \(GuestContract.Schema.envelopeList.rawValue) ---"))
    }

    @Test func factoryGoalDumpsProtocolNotHandwrittenEssays() throws {
        let goal = slackFullSyncGoal()
        #expect(goal.contains("Scope id: full_sync"))
        #expect(goal.contains("--- connector-contract.json ---"))
        #expect(goal.contains("They cannot add ops"))
        #expect(goal.contains("Slack Web API notes"))
        #expect(ConnectorContractPrompts.reviewerGuide().contains("If a rule is not in the JSON"))
        #expect(ConnectorContractPrompts.builderGuide(forUserGoal: goal).contains("--- connector-contract.json ---"))
        #expect(ConnectorContractPrompts.builderGuide(forUserGoal: goal).contains("--- vendor slack ---"))
        #expect(ConnectorContractPrompts.reviewerGuide(forUserGoal: goal).contains("--- vendor slack ---"))
        #expect(!ConnectorContractPrompts.builderGuide().contains("--- vendor slack ---"))
        #expect(ConnectorContractPrompts.builderGuide(forUserGoal: goal).contains("--- \(GuestContract.Schema.connectorParams.rawValue) ---"))
    }

    @Test func legacySendOnlyInputStillBuildsFullSyncGoal() throws {
        let sendOnly = """
        {"pluginType":"connector","vendor":"slack","scope":"send_only","description":"x"}
        """
        let input = try PluginFactoryCreateInput.decodeJSON(sendOnly)
        #expect(input.scope == .fullSync)
        let goal = input.connectorBuildGoal(crawlSummary: nil)
        #expect(goal.contains("Scope id: full_sync"))
        #expect(!goal.contains("Scope id: send_only"))
    }

    @Test func validatorAcceptsLegalSlackFullSyncHopRun() throws {
        try PluginFactoryDraftValidator.validateDirectTest(
            draft: slackFullSyncDraft(),
            manifest: try slackFullSyncManifest(),
            hopRun: legalSlackFullSyncHopRun()
        )
    }

    @Test func validatorRejectsHistoryURLOnSyncThreadsHop() throws {
        try expectDirectTestFailure(
            containing: "must not call",
            hopRun: legalSlackFullSyncHopRun(
                syncURL: "https://slack.com/api/conversations.history?channel=C1"
            )
        )
    }

    @Test func validatorRejectsRepliesURLOnChannelPoll() throws {
        try expectDirectTestFailure(
            containing: "must not call",
            hopRun: legalSlackFullSyncHopRun(
                channelPollURL: "https://slack.com/api/conversations.replies?channel=C1&ts=1"
            )
        )
    }

    @Test func validatorRejectsHistoryURLOnReplyPoll() throws {
        try expectDirectTestFailure(
            containing: "must not call",
            hopRun: legalSlackFullSyncHopRun(
                replyPollURL: "https://slack.com/api/conversations.history?channel=C1"
            )
        )
    }

    @Test func validatorUsesPairedHopWhenRequestOmitsMessagingOp() throws {
        let testInput = slackFullSyncTestInput(syncRequestParams: "{}")
        try expectDirectTestFailure(
            containing: "must not call",
            draft: slackFullSyncDraft(testInput: testInput),
            hopRun: legalSlackFullSyncHopRun(
                syncURL: "https://slack.com/api/conversations.history?channel=C1"
            )
        )
    }

    @Test func validatorTreatsParentOnPairedHttpResultsHopAsReplyPoll() throws {
        let testInput = slackFullSyncTestInput(
            replyRequestParams: #"{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}"#,
            replyResultsParams: #"{"messaging_op":"poll_inbox","parent_vendor_message_id":"1"}"#
        )
        try PluginFactoryDraftValidator.validateDirectTest(
            draft: slackFullSyncDraft(testInput: testInput),
            manifest: try slackFullSyncManifest(),
            hopRun: legalSlackFullSyncHopRun()
        )
    }

    @Test func validatorRequiresNonEmptyDirectTestThreadsAndMessages() throws {
        try expectDirectTestFailure(
            containing: "non-empty threads",
            hopRun: legalSlackFullSyncHopRun(threadsJSON: "[]")
        )
        try expectDirectTestFailure(
            containing: "non-empty messages",
            hopRun: legalSlackFullSyncHopRun(messagesJSON: "[]")
        )
    }

    @Test func validatorRejectsThreadEmitMissingTitleFromSchema() throws {
        try expectDirectTestFailure(
            containing: "title",
            hopRun: legalSlackFullSyncHopRun(threadsJSON: #"[{"vendor_thread_id":"C1"}]"#)
        )
    }

    @Test func validatorRejectsSyncThreadsHopWithWrongKind() throws {
        let testInput = Data(
            """
            {"hops":[
              {"kind":"message_in_room","params":{"messaging_op":"sync_threads"}},
              {"kind":"http_results","http_results":[{"request_id":"sync-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"sync_threads"}},
              {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
              {"kind":"http_results","http_results":[{"request_id":"poll-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"poll_inbox"}},
              {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123","parent_vendor_message_id":"1"}},
              {"kind":"http_results","http_results":[{"request_id":"replies-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"poll_inbox"}},
              {"kind":"message_in_room","params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hi"}},
              {"kind":"http_results","http_results":[{"request_id":"send-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"send_message"}}
            ]}
            """.utf8
        )
        do {
            try PluginFactoryDraftValidator.validateStructure(
                draft: slackFullSyncDraft(testInput: testInput),
                manifest: try slackFullSyncManifest()
            )
            Issue.record("Expected hop kind mismatch to fail structure validation.")
        } catch let error as PluginFactoryError {
            #expect(error.localizedDescription.contains("hop kind must be manual"))
        }
    }

    @Test func hopEventRejectsUnknownMessagingOp() {
        #expect(throws: GuestContractError.self) {
            try GuestContractValidation.validateHopEventJSON(
                Data(#"{"kind":"manual","params":{"messaging_op":"react"}}"#.utf8)
            )
        }
    }
}

private func slackFullSyncGoal() -> String {
    PluginFactoryCreateInput.makeConnector(
        vendor: .slack,
        scope: .fullSync,
        userDescription: ""
    ).connectorBuildGoal(crawlSummary: "Slack Web API notes")
}

private func slackFullSyncManifestJSON() -> String {
    """
    {"$schema":"\(PluginContract.agentPluginSchema)","name":"slack-connection","version":"1.0.0",\
    "extensions":{"app.derrick":{"entrypoint":"./app.derrick/plugin.go","role":"connector","messaging_ops":["sync_threads","poll_inbox","send_message"]}}}
    """
}

private func slackFullSyncManifest() throws -> AgentPluginManifest {
    try AgentPluginManifest.decode(Data(slackFullSyncManifestJSON().utf8))
}

private func slackFullSyncDraft(testInput: Data = slackFullSyncTestInput()) -> PluginFactoryDraft {
    PluginFactoryDraft(
        manifestJSON: slackFullSyncManifestJSON(),
        guestSource: "print('unused')",
        testInput: testInput,
        userGoal: slackFullSyncGoal()
    )
}

private func slackFullSyncTestInput(
    syncRequestParams: String = #"{"messaging_op":"sync_threads"}"#,
    replyRequestParams: String = #"{"messaging_op":"poll_inbox","vendor_thread_id":"C123","parent_vendor_message_id":"1"}"#,
    replyResultsParams: String = #"{"messaging_op":"poll_inbox"}"#
) -> Data {
    Data(
        """
        {"hops":[
          {"kind":"manual","params":\(syncRequestParams)},
          {"kind":"http_results","http_results":[{"request_id":"sync-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"sync_threads"}},
          {"kind":"manual","params":{"messaging_op":"poll_inbox","vendor_thread_id":"C123"}},
          {"kind":"http_results","http_results":[{"request_id":"poll-1","status":200,"body":"{\\"ok\\":true,\\"messages\\":[{\\"ts\\":\\"1\\"}]}"}],"params":{"messaging_op":"poll_inbox"}},
          {"kind":"manual","params":\(replyRequestParams)},
          {"kind":"http_results","http_results":[{"request_id":"replies-1","status":200,"body":"{\\"ok\\":true}"}],"params":\(replyResultsParams)},
          {"kind":"message_in_room","params":{"messaging_op":"send_message","vendor_thread_id":"C123","text":"hi"}},
          {"kind":"http_results","http_results":[{"request_id":"send-1","status":200,"body":"{\\"ok\\":true}"}],"params":{"messaging_op":"send_message"}}
        ]}
        """.utf8
    )
}

private func legalSlackFullSyncHopRun(
    syncURL: String = "https://slack.com/api/conversations.list",
    channelPollURL: String = "https://slack.com/api/conversations.history?channel=C1",
    replyPollURL: String = "https://slack.com/api/conversations.replies?channel=C1&ts=1",
    sendURL: String = "https://slack.com/api/chat.postMessage",
    threadsJSON: String = #"[{"vendor_thread_id":"C1","title":"general"}]"#,
    messagesJSON: String = #"[{"vendor_thread_id":"C1","vendor_message_id":"1","direction":"inbound","sender":"a","body":"hi","created_at":"1"}]"#
) -> PluginFactoryHopTestRun {
    let hops = [
        requestHop(id: "sync-1", method: "GET", url: syncURL),
        emitHop(#"{"verb":"result.emit","threads":\#(threadsJSON)}"#),
        requestHop(id: "poll-1", method: "GET", url: channelPollURL),
        emitHop(#"{"verb":"result.emit","messages":\#(messagesJSON)}"#),
        requestHop(id: "replies-1", method: "GET", url: replyPollURL),
        emitHop(#"{"verb":"result.emit","messages":\#(messagesJSON)}"#),
        requestHop(id: "send-1", method: "POST", url: sendURL),
        emitHop(#"{"verb":"result.emit","sent_message":{"vendor_message_id":"2","created_at":"2"}}"#),
    ]
    return PluginFactoryHopTestRun(final: hops.last!, hopResults: hops)
}

private func requestHop(id: String, method: String, url: String) -> PluginFactoryExecutionResult {
    PluginFactoryExecutionResult(
        exitCode: 0,
        stdout: Data(#"[{"verb":"http.request","request_id":"\#(id)","method":"\#(method)","url":"\#(url)"}]"#.utf8)
    )
}

private func emitHop(_ object: String) -> PluginFactoryExecutionResult {
    PluginFactoryExecutionResult(exitCode: 0, stdout: Data("[\(object)]".utf8))
}

private func expectDirectTestFailure(
    containing needle: String,
    draft: PluginFactoryDraft = slackFullSyncDraft(),
    hopRun: PluginFactoryHopTestRun
) throws {
    do {
        try PluginFactoryDraftValidator.validateDirectTest(
            draft: draft,
            manifest: try slackFullSyncManifest(),
            hopRun: hopRun
        )
        Issue.record("Expected direct test validation to fail.")
    } catch let error as PluginFactoryError {
        #expect(error.localizedDescription.contains(needle))
    }
}
