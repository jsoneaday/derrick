import Foundation

/// How the factory must prove a plugin works. Directions depend on the plugin type, not the vendor.
public enum PluginAcceptanceDirections: Sendable {
    public static func builderText(forUserGoal userGoal: String?) -> String {
        switch kind(forUserGoal: userGoal) {
        case .messagingConnector:
            return """
            Write the tests after the code. Do not put http_results or any made-up service reply in test_input_json.
            Each messaging op is its own hop with params.messaging_op only.
            The test must prove the user's statement of what failure is does not happen.
            If failure is that it cannot connect, the live test must connect.
            If failure is that it cannot send, the live test must send a real test message.
            If failure is that it cannot receive, the live test must receive.
            After the code review passes, the host runs these hops against the real service and the reviewer confirms they completed.
            sync_threads is complete only when result.emit includes threads.
            poll_inbox is complete only when result.emit includes messages.
            send_message is complete only when result.emit includes sent_message.
            """
        case .newsReader:
            return """
            Acceptance test for a news reader (live, not a fixture):
            The test must start from the source the user named and emit http.request for that fetch.
            The host performs that request. The guest must turn the real response into the items the user asked for.
            A saved HTML or JSON body in test_input_json is not a test.
            The user's statement of what is unacceptable is the failure oracle.
            """
        case .customCapability:
            return """
            Acceptance test for a custom plugin (live, not a fixture):
            If the plugin calls the network, the test hop must emit http.request and must not include a prepared http_results body.
            The host performs those requests. The live result must show the outcome the user asked for.
            A constant success body is not a test.
            The user's statement of what is unacceptable is the failure oracle.
            """
        }
    }

    public static func reviewerText(forUserGoal userGoal: String?) -> String {
        """
        If the direct test output begins with CODE_REVIEW, tests have not run. Judge the source and the test plan only. \
        Reject a test plan that contains http_results or would not prove the user's failure statement.
        If the direct test output begins with LIVE_TEST, the tests have been run against the real service. \
        Confirm they completed. Reject when a required action did not complete or the result is what the user called unacceptable.
        \(builderText(forUserGoal: userGoal))
        """
    }

    public static func kind(forUserGoal userGoal: String?) -> Kind {
        let ops = PluginFactoryValidationExpectations.requiredMessagingOps(from: userGoal)
        if !ops.isEmpty { return .messagingConnector }
        let text = userGoal?.lowercased() ?? ""
        if text.contains("news") { return .newsReader }
        return .customCapability
    }

    public enum Kind: Sendable {
        case messagingConnector
        case newsReader
        case customCapability
    }
}

/// Decides whether a live acceptance transcript satisfied the plugin type. No vendor knowledge.
public enum PluginLiveAcceptance: Sendable {
    public static func liveHops(in testInput: Data) -> [PluginHopEvent] {
        guard let script = try? PluginFactoryTestScript.parse(testInput) else { return [] }
        return script.hops.filter { $0.kind != .httpResults }
    }

    public static func firstThreadID(in stdout: String) -> String? {
        guard let range = stdout.range(of: "\"vendor_thread_id\"") else { return nil }
        let tail = stdout[range.upperBound...]
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        let after = tail[tail.index(after: colon)...].drop { $0.isWhitespace }
        guard after.first == "\"" else { return nil }
        let rest = after.dropFirst()
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let id = String(rest[..<end])
        return id.isEmpty ? nil : id
    }

    public static func prepared(
        _ hop: PluginHopEvent,
        discoveredThreadID: String?
    ) -> PluginHopEvent {
        var params = hop.params ?? [:]
        let op = params["messaging_op"]?.stringValue
        if op == "poll_inbox" || op == "send_message" {
            let existing = params["vendor_thread_id"]?.stringValue ?? ""
            if existing.isEmpty, let discoveredThreadID {
                params["vendor_thread_id"] = .string(discoveredThreadID)
            }
        }
        if op == "send_message" {
            let text = params["text"]?.stringValue ?? ""
            if text.isEmpty {
                params["text"] = .string("Derrick acceptance check")
            }
        }
        return PluginHopEvent(kind: hop.kind, httpResults: nil, params: params)
    }

    public static func problem(
        testInput: Data,
        stdout: String,
        stderr: String,
        exitCode: Int32,
        messagingOps: [String]
    ) -> String? {
        let hops = liveHops(in: testInput)
        if hops.isEmpty {
            return """
            Live acceptance failed. The test script has no hop for the host to run. \
            Fixture http_results are not a test.
            """
        }
        if exitCode != 0 {
            return "Live acceptance failed.\n\(clip(stderr))\n\(clip(stdout))"
        }
        guard !messagingOps.isEmpty else { return nil }
        let started = Set(hops.compactMap { $0.params?["messaging_op"]?.stringValue })
        var missing: [String] = []
        for op in messagingOps {
            guard started.contains(op) else {
                missing.append("\(op) was not started as a live hop")
                continue
            }
            if let field = successField(for: op), !stdout.contains("\"\(field)\"") {
                missing.append("\(op) did not return \(field)")
            }
        }
        guard !missing.isEmpty else { return nil }
        return """
        Live acceptance failed: \(missing.joined(separator: "; ")).
        \(clip(stdout))
        """
    }

    public static func successField(for messagingOp: String) -> String? {
        switch messagingOp {
        case "sync_threads": return "threads"
        case "poll_inbox": return "messages"
        case "send_message": return "sent_message"
        default: return nil
        }
    }

    private static func clip(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.count <= 500 { return collapsed }
        return String(collapsed.prefix(500)) + "…"
    }
}
