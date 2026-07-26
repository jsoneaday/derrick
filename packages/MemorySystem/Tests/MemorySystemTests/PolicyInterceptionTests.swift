import XCTest
@testable import MemorySystem

final class PolicyInterceptionTests: XCTestCase {
    func test_assistantChunkEvent_creation() {
        let event = AssistantChunkEvent(
            sessionID: "session-1",
            chunkIndex: 0,
            content: "Hello, "
        )

        XCTAssertNotNil(event.eventID)
        XCTAssertEqual(event.sessionID, "session-1")
        XCTAssertEqual(event.chunkIndex, 0)
        XCTAssertEqual(event.content, "Hello, ")
    }

    func test_assistantCompletionEvent_creation() {
        let event = AssistantCompletionEvent(
            sessionID: "session-1",
            fullCompletion: "Hello, world!",
            chunkCount: 2
        )

        XCTAssertNotNil(event.eventID)
        XCTAssertEqual(event.fullCompletion, "Hello, world!")
        XCTAssertEqual(event.chunkCount, 2)
    }

    func test_toolInvocationEvent_creation() {
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "read_file",
            argumentsJSON: #"{"path": "/etc/config.txt"}"#
        )

        XCTAssertNotNil(event.eventID)
        XCTAssertEqual(event.toolName, "read_file")
        XCTAssertTrue(event.argumentsJSON.contains("path"))
    }

    func test_toolResultEvent_creation() {
        let event = ToolResultEvent(
            sessionID: "session-1",
            toolName: "read_file",
            resultJSON: #"{"content": "config data"}"#
        )

        XCTAssertNotNil(event.eventID)
        XCTAssertEqual(event.toolName, "read_file")
        XCTAssertNil(event.error)
    }

    func test_statusUpdateEvent_creation() {
        let event = StatusUpdateEvent(
            sessionID: "session-1",
            message: "Processing..."
        )

        XCTAssertNotNil(event.eventID)
        XCTAssertEqual(event.message, "Processing...")
    }

    func test_policyInterceptionEvent_timestamp() {
        let now = Date()
        let chunkEvent = AssistantChunkEvent(
            sessionID: "session-1",
            chunkIndex: 0,
            content: "test",
            timestamp: now
        )
        let event = PolicyInterceptionEvent.assistantChunk(chunkEvent)

        XCTAssertEqual(event.timestamp, now)
    }

    func test_defaultPolicyInterceptor_allowsContent() async throws {
        let interceptor = DefaultPolicyInterceptor()
        let event = AssistantChunkEvent(
            sessionID: "session-1",
            chunkIndex: 0,
            content: "Safe content"
        )

        let result = try await interceptor.interceptAssistantChunk(event)
        XCTAssertEqual(result, .allowed("Safe content"))
    }

    func test_defaultPolicyInterceptor_withoutPolicy_passesThrough() async throws {
        let interceptor = DefaultPolicyInterceptor(policy: nil)
        let event = AssistantChunkEvent(
            sessionID: "session-1",
            chunkIndex: 0,
            content: "Any content"
        )

        let result = try await interceptor.interceptAssistantChunk(event)
        XCTAssertEqual(result, .allowed("Any content"))
    }

    func test_events_are_hashable() {
        let event1 = AssistantChunkEvent(
            sessionID: "session-1",
            chunkIndex: 0,
            content: "test"
        )
        let event2 = AssistantChunkEvent(
            sessionID: "session-1",
            chunkIndex: 0,
            content: "test"
        )

        XCTAssertNotEqual(event1, event2)
    }

    func test_events_are_sendable() async {
        let event = AssistantChunkEvent(
            sessionID: "session-1",
            chunkIndex: 0,
            content: "test"
        )

        let task = Task {
            return event.content
        }

        let result = await task.value
        XCTAssertEqual(result, "test")
    }

    func test_toolResultEvent_withError() {
        let event = ToolResultEvent(
            sessionID: "session-1",
            toolName: "read_file",
            resultJSON: "{}",
            error: "File not found"
        )

        XCTAssertEqual(event.error, "File not found")
    }
}

struct MockResponseContentPolicy: PolicyEvaluator {
    var shouldAllow = true
    var shouldDeny = false
    var denyReason = "Policy rejected"

    func evaluateAssistantChunk(_ event: AssistantChunkEvent) async throws -> PolicyDecisionOutcome {
        if shouldDeny {
            return .deny(reason: denyReason)
        }
        return shouldAllow ? .allow : .confirm(requiredFields: [])
    }

    func evaluateAssistantCompletion(_ event: AssistantCompletionEvent) async throws -> PolicyDecisionOutcome {
        if shouldDeny {
            return .deny(reason: denyReason)
        }
        return shouldAllow ? .allow : .confirm(requiredFields: [])
    }
}

final class PolicyInterceptorTests: XCTestCase {
    func test_interceptor_allows_with_policy() async throws {
        var policy = MockResponseContentPolicy()
        policy.shouldAllow = true

        let interceptor = DefaultPolicyInterceptor(policy: policy)
        let event = AssistantChunkEvent(
            sessionID: "session-1",
            chunkIndex: 0,
            content: "Hello"
        )

        let result = try await interceptor.interceptAssistantChunk(event)
        XCTAssertEqual(result, .allowed("Hello"))
    }

    func test_interceptor_denies_with_policy() async throws {
        var policy = MockResponseContentPolicy()
        policy.shouldAllow = false
        policy.shouldDeny = true
        policy.denyReason = "Policy violation"

        let interceptor = DefaultPolicyInterceptor(policy: policy)
        let event = AssistantChunkEvent(
            sessionID: "session-1",
            chunkIndex: 0,
            content: "Unsafe content"
        )

        let result = try await interceptor.interceptAssistantChunk(event)
        XCTAssertEqual(result, .denied(reason: "Policy violation"))
    }

    func test_interceptor_redacts_content() async throws {
        let interceptor = DefaultPolicyInterceptor()
        let event = AssistantCompletionEvent(
            sessionID: "session-1",
            fullCompletion: "Email is test@example.com here",
            chunkCount: 1
        )

        let result = try await interceptor.interceptAssistantCompletion(event)
        XCTAssertEqual(result, .allowed("Email is test@example.com here"))
    }
}
