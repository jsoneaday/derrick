import Foundation
import Testing
@testable import Structure

@Suite struct LLMHTTPTimeoutsTests {
    @Test func idleTimeoutOverridesURLRequestDefault() {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        #expect(request.timeoutInterval == 60)
        LLMHTTPTimeouts.applyIdleTimeout(to: &request)
        #expect(request.timeoutInterval == LLMHTTPTimeouts.requestIdleSeconds)
        #expect(LLMHTTPTimeouts.requestIdleSeconds == 180)
        #expect(LLMHTTPTimeouts.resourceSeconds == 480)
    }

    @Test func streamingSessionUsesLongerIdleAndResourceTimeouts() {
        let config = LLMHTTPTimeouts.streamingConfiguration()
        #expect(config.timeoutIntervalForRequest == LLMHTTPTimeouts.requestIdleSeconds)
        #expect(config.timeoutIntervalForResource == LLMHTTPTimeouts.resourceSeconds)
        #expect(config.waitsForConnectivity)
    }

    @Test func detectsURLSessionTimeoutDescription() {
        #expect(LLMHTTPTimeouts.isTimeoutDescription("The request timed out."))
        #expect(LLMHTTPTimeouts.isTimeoutDescription("The plugin builder model timed out."))
        #expect(!LLMHTTPTimeouts.isTimeoutDescription("Plugin review rejected the draft."))
        let timedOut = URLError(.timedOut)
        #expect(LLMHTTPTimeouts.isTimeout(timedOut))
    }
}
