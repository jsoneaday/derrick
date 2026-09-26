import Foundation
import Structure
import Testing
@testable import ui

@Suite struct FactoryModelStreamTimeoutTests {
    private actor BuilderActor {
        func collect(
            _ stream: AsyncThrowingStream<AgentStreamEvent, Error>,
            timeoutNanoseconds: UInt64
        ) async throws -> String {
            let (text, _) = try await collectFactoryModelStream(
                stream,
                role: "builder",
                timeoutNanoseconds: timeoutNanoseconds
            )
            return text
        }
    }

    @Test func stalledBuilderStreamFailsInsteadOfHanging() async throws {
        let stream = AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            continuation.yield(.text("partial draft"))
        }
        let started = ContinuousClock().now
        do {
            _ = try await BuilderActor().collect(stream, timeoutNanoseconds: 300_000_000)
            Issue.record("A stream that never finishes must time out")
        } catch let error as PluginFactoryModelError {
            #expect(error == .timedOut("builder"))
        }
        #expect(ContinuousClock().now - started < .seconds(5))
    }
}
