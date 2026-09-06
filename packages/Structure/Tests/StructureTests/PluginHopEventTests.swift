import Foundation
import Structure
import Testing

@Suite struct PluginHopEventTests {
    @Test func mergingHTTPResultsKeepsEarlierPagesAndReplacesSameID() {
        let prior = PluginHopEvent(
            kind: .httpResults,
            httpResults: [
                HostHTTPResponse(requestID: "sync-1", status: 200, body: "page-1"),
            ],
            params: ["messaging_op": .string("sync_threads")]
        )
        let latest = PluginHopEvent(
            kind: .httpResults,
            httpResults: [
                HostHTTPResponse(requestID: "sync-1", status: 200, body: "page-1-updated"),
                HostHTTPResponse(requestID: "sync-2", status: 200, body: "page-2"),
            ],
            params: ["messaging_op": .string("sync_threads")]
        )

        let merged = prior.mergingLatestHTTPResults(latest)
        let bodies = Dictionary(
            uniqueKeysWithValues: (merged.httpResults ?? []).map { ($0.requestID, $0.body) }
        )
        #expect(merged.kind == .httpResults)
        #expect(bodies["sync-1"] == "page-1-updated")
        #expect(bodies["sync-2"] == "page-2")
        #expect(merged.params?["messaging_op"]?.stringValue == "sync_threads")
    }

    @Test func pluginInvokeHopBudgetIsLargerThanScriptExec() {
        #expect(PluginContract.maxPluginInvokeHops > PluginContract.maxHops)
    }
}

@Suite struct ConnectorPluginExecutionMessageTests {
    @Test func mapsHopBudgetWithoutHostJargon() {
        let message = ConnectorPluginExecutionMessage.userFacing(
            fromDetail: "Approved plugin failed during execution (exit 1): Hop budget exceeded."
        )
        #expect(message == ConnectorPluginExecutionMessage.tookTooManySteps)
        #expect(message?.localizedCaseInsensitiveContains("hop") != true)
    }

    @Test func ignoresUnrelatedPluginFailures() {
        #expect(
            ConnectorPluginExecutionMessage.userFacing(fromDetail: "Slack returned no messages") == nil
        )
    }
}
