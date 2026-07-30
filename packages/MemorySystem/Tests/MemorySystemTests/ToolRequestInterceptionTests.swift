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

    // MARK: - interceptAndRun (item 4: confirm-before-proceed)

    private final class CallProbe: @unchecked Sendable {
        var confirmCalled = false
        var proceedCalled = false
        var proceedTool: String?
        var seenFields: [String] = []
    }

    func test_interceptAndRun_allow_calls_proceed_only() async throws {
        struct AllowPolicy: ToolGovernancePolicy {
            func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolGovernanceOutcome {
                .allow
            }
        }

        let interceptor = DefaultToolRequestInterceptor(policy: AllowPolicy())
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "read_file",
            argumentsJSON: #"{}"#
        )

        let probe = CallProbe()
        let result = try await interceptor.interceptAndRun(
            event,
            confirm: { _, _ in
                probe.confirmCalled = true
                return .cancelled(actor: nil)
            },
            proceed: { gated in
                probe.proceedTool = gated.toolName
                return "ok"
            }
        )

        XCTAssertEqual(result, "ok")
        XCTAssertFalse(probe.confirmCalled)
        XCTAssertEqual(probe.proceedTool, "read_file")
    }

    func test_interceptAndRun_deny_throws_without_proceed() async throws {
        struct DenyPolicy: ToolGovernancePolicy {
            func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolGovernanceOutcome {
                .deny(reason: "blocked by policy")
            }
        }

        let interceptor = DefaultToolRequestInterceptor(policy: DenyPolicy())
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "shell_exec",
            argumentsJSON: #"{}"#
        )

        let probe = CallProbe()
        do {
            _ = try await interceptor.interceptAndRun(
                event,
                confirm: { _, _ in .cancelled(actor: nil) },
                proceed: { _ -> String in
                    probe.proceedCalled = true
                    return "should not run"
                }
            )
            XCTFail("Expected deny error")
        } catch ToolInvocationInterceptionError.denied(let reason) {
            XCTAssertEqual(reason, "blocked by policy")
        }
        XCTAssertFalse(probe.proceedCalled)
    }

    func test_interceptAndRun_confirm_approved_then_proceed() async throws {
        struct ConfirmPolicy: ToolGovernancePolicy {
            func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolGovernanceOutcome {
                .confirm(requiredFields: ["user_approval"])
            }
        }

        let interceptor = DefaultToolRequestInterceptor(policy: ConfirmPolicy())
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "delete_file",
            argumentsJSON: #"{"path":"/tmp/a"}"#
        )

        let probe = CallProbe()
        let result = try await interceptor.interceptAndRun(
            event,
            confirm: { confirmEvent, fields in
                probe.seenFields = fields
                return .approved(
                    ToolInvocationEvent(
                        sessionID: confirmEvent.sessionID,
                        toolName: confirmEvent.toolName,
                        argumentsJSON: #"{"path":"/tmp/edited"}"#,
                        timestamp: confirmEvent.timestamp
                    )
                )
            },
            proceed: { gated in
                XCTAssertEqual(gated.argumentsJSON, #"{"path":"/tmp/edited"}"#)
                return gated.argumentsJSON
            }
        )

        XCTAssertEqual(probe.seenFields, ["user_approval"])
        XCTAssertEqual(result, #"{"path":"/tmp/edited"}"#)
    }

    func test_interceptAndRun_confirm_cancelled_throws_without_proceed() async throws {
        struct ConfirmPolicy: ToolGovernancePolicy {
            func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolGovernanceOutcome {
                .confirm(requiredFields: ["user_approval"])
            }
        }

        let interceptor = DefaultToolRequestInterceptor(policy: ConfirmPolicy())
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "delete_file",
            argumentsJSON: #"{}"#
        )

        let probe = CallProbe()
        do {
            _ = try await interceptor.interceptAndRun(
                event,
                confirm: { _, _ in .cancelled(actor: "tester") },
                proceed: { _ -> String in
                    probe.proceedCalled = true
                    return "no"
                }
            )
            XCTFail("Expected cancelled error")
        } catch ToolInvocationInterceptionError.cancelled(let reason) {
            XCTAssertTrue(reason.contains("cancelled"))
            XCTAssertTrue(reason.contains("tester"))
        }
        XCTAssertFalse(probe.proceedCalled)
    }

    func test_interceptAndRun_redact_then_proceed_with_redacted_event() async throws {
        struct RedactPolicy: ToolGovernancePolicy {
            func evaluateToolInvocation(_ event: ToolInvocationEvent) async throws -> ToolGovernanceOutcome {
                .redact(argumentKey: "token", pattern: ".+", replacement: "[REDACTED]")
            }
        }

        let interceptor = DefaultToolRequestInterceptor(policy: RedactPolicy())
        let event = ToolInvocationEvent(
            sessionID: "session-1",
            toolName: "auth",
            argumentsJSON: #"{"token":"secret"}"#
        )

        let result = try await interceptor.interceptAndRun(
            event,
            confirm: { _, _ in .cancelled(actor: nil) },
            proceed: { gated in
                gated.argumentsJSON
            }
        )

        XCTAssertTrue(result.contains("[REDACTED]"))
        XCTAssertFalse(result.contains("secret"))
    }
}
