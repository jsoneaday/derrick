import XCTest
@testable import MemorySystem

final class ToolRequestInterceptionTests: XCTestCase {
    func test_toolInvocationEvent_creation() {
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "read_file",
            argumentsJSON: #"{"path": "/etc/config.txt"}"#
        )

        XCTAssertNotNil(event.eventID)
        XCTAssertEqual(event.sessionID, "session-1")
        XCTAssertEqual(event.toolName, "read_file")
        XCTAssertTrue(event.argumentsJSON.contains("path"))
    }

    func test_toolResultEvent_creation() {
        let event = ToolResultEvent(
            sessionID: "session-1",
            toolName: "read_file",
            resultJSON: #"{"content": "file content"}"#
        )

        XCTAssertNotNil(event.eventID)
        XCTAssertEqual(event.toolName, "read_file")
        XCTAssertNil(event.error)
    }

    func test_toolResultEvent_with_error() {
        let event = ToolResultEvent(
            sessionID: "session-1",
            toolName: "read_file",
            resultJSON: "{}",
            error: "File not found"
        )

        XCTAssertEqual(event.error, "File not found")
    }

    func test_toolInvocationEvent_timestamp() {
        let now = Date()
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "read_file",
            argumentsJSON: "{}",
            timestamp: now
        )

        XCTAssertEqual(event.timestamp, now)
    }

    func test_toolResultEvent_timestamp() {
        let now = Date()
        let event = ToolResultEvent(
            sessionID: "session-1",
            toolName: "read_file",
            resultJSON: "{}",
            timestamp: now
        )

        XCTAssertEqual(event.timestamp, now)
    }

    func test_toolInvocationEvent_sendable() async {
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "read_file",
            argumentsJSON: "{}"
        )

        let task = Task {
            return event.toolName
        }

        let result = await task.value
        XCTAssertEqual(result, "read_file")
    }

    func test_toolRequestEvent_hashable() {
        let event1 = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "read_file",
            argumentsJSON: "{}"
        )
        let event2 = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "read_file",
            argumentsJSON: "{}"
        )

        XCTAssertNotEqual(event1, event2)
    }
}

struct MockToolGovernancePolicy: ToolGovernancePolicy {
    var shouldAllow = true
    var shouldDeny = false
    var denyReason = "Tool not allowed"

    func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolGovernanceOutcome {
        if shouldDeny {
            return .deny(reason: denyReason)
        }
        return shouldAllow ? .allow : .confirm(requiredFields: ["approval"])
    }
}

final class ToolRequestInterceptorTests: XCTestCase {
    func test_defaultInterceptor_allows_tool() async throws {
        var policy = MockToolGovernancePolicy()
        policy.shouldAllow = true

        let interceptor = DefaultToolRequestInterceptor(policy: policy)
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "read_file",
            argumentsJSON: #"{"path": "/etc/config.txt"}"#
        )

        let result = try await interceptor.interceptToolInvocation(event)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.toolName, "read_file")
    }

    func test_defaultInterceptor_denies_tool() async throws {
        var policy = MockToolGovernancePolicy()
        policy.shouldAllow = false
        policy.shouldDeny = true
        policy.denyReason = "Tool is restricted"

        let interceptor = DefaultToolRequestInterceptor(policy: policy)
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "shell_exec",
            argumentsJSON: #"{"cmd": "rm -rf /"}"#
        )

        let result = try await interceptor.interceptToolInvocation(event)
        XCTAssertNil(result)
    }

    func test_defaultInterceptor_without_policy() async throws {
        let interceptor = DefaultToolRequestInterceptor(policy: nil)
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "read_file",
            argumentsJSON: #"{"path": "/home/user/file.txt"}"#
        )

        let result = try await interceptor.interceptToolInvocation(event)
        XCTAssertEqual(result?.toolName, "read_file")
        XCTAssertEqual(result?.argumentsJSON, event.argumentsJSON)
    }

    func test_defaultInterceptor_redacts_arguments() async throws {
        struct RedactingPolicy: ToolGovernancePolicy {
            func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolGovernanceOutcome {
                return .redact(argumentKey: "password", pattern: ".+", replacement: "[REDACTED]")
            }
        }

        let interceptor = DefaultToolRequestInterceptor(policy: RedactingPolicy())
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "authenticate",
            argumentsJSON: #"{"username": "admin", "password": "secret123"}"#
        )

        let result = try await interceptor.interceptToolInvocation(event)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.argumentsJSON.contains("[REDACTED]"))
        XCTAssertFalse(result!.argumentsJSON.contains("secret123"))
    }

    func test_interceptionEvent_in_enum() {
        let invocationEvent = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "read_file",
            argumentsJSON: "{}"
        )
        let event = PolicyInterceptionEvent.toolInvocation(invocationEvent)

        XCTAssertEqual(event.timestamp, invocationEvent.timestamp)
    }

    func test_toolResult_interceptionEvent() {
        let resultEvent = ToolResultEvent(
            sessionID: "session-1",
            toolName: "read_file",
            resultJSON: #"{"content": "data"}"#
        )
        let event = PolicyInterceptionEvent.toolResult(resultEvent)

        XCTAssertEqual(event.timestamp, resultEvent.timestamp)
    }

    func test_confirm_outcome_preserves_tool_name() async throws {
        struct ConfirmingPolicy: ToolGovernancePolicy {
            func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolGovernanceOutcome {
                return .confirm(requiredFields: ["user_consent"])
            }
        }

        let interceptor = DefaultToolRequestInterceptor(policy: ConfirmingPolicy())
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "delete_file",
            argumentsJSON: #"{"path": "/tmp/file.txt"}"#
        )

        let result = try await interceptor.interceptToolInvocation(event)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.toolName, "delete_file")
    }

    func test_evaluateToolInvocation_returns_confirm_with_requiredFields() async throws {
        struct ConfirmingPolicy: ToolGovernancePolicy {
            func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolGovernanceOutcome {
                .confirm(requiredFields: ["user_consent", "ticket_id"])
            }
        }

        let interceptor = DefaultToolRequestInterceptor(policy: ConfirmingPolicy())
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "delete_file",
            argumentsJSON: #"{"path": "/tmp/file.txt"}"#
        )

        let decision = try await interceptor.evaluateToolInvocation(event)
        switch decision {
        case .confirm(let confirmedEvent, let requiredFields):
            XCTAssertEqual(confirmedEvent.toolName, "delete_file")
            XCTAssertEqual(requiredFields, ["user_consent", "ticket_id"])
        default:
            XCTFail("Expected confirm decision")
        }
    }
}
