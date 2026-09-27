import Foundation
import Structure
import XCTest

/// Applying-layer coverage formerly owned by MemorySystem interceptor tests.
final class GuardrailApplyingTests: XCTestCase {
    func test_toolApplying_allow_returnsEvent() async throws {
        let event = ToolInvocationEvent(sessionID: "s", toolName: "t", argumentsJSON: "{}")
        let gated = try await ToolInvocationGuardrailApplying().apply(.allow, for: event)
        XCTAssertEqual(gated.toolName, "t")
    }

    func test_toolApplying_deny_throws() async {
        let event = ToolInvocationEvent(sessionID: "s", toolName: "t", argumentsJSON: "{}")
        do {
            _ = try await ToolInvocationGuardrailApplying().apply(.deny(reason: "no"), for: event)
            XCTFail("expected deny")
        } catch let error as ToolInvocationGuardrailError {
            guard case .denied(let reason) = error else {
                return XCTFail("expected denied")
            }
            XCTAssertEqual(reason, "no")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_toolApplying_redactArgument() async throws {
        let event = ToolInvocationEvent(
            sessionID: "s",
            toolName: "t",
            argumentsJSON: #"{"token":"abc-secret"}"#
        )
        let gated = try await ToolInvocationGuardrailApplying().apply(
            .redactArgument(argumentKey: "token", pattern: "secret", replacement: "[x]"),
            for: event
        )
        XCTAssertTrue(gated.argumentsJSON.contains("[x]"))
        XCTAssertFalse(gated.argumentsJSON.contains("secret"))
    }

    func test_toolApplying_confirmHITL_approved() async throws {
        let event = ToolInvocationEvent(sessionID: "s", toolName: "t", argumentsJSON: #"{"a":1}"#)
        let hitl = ImmediateGuardrailHITLPresenting(
            resolution: .approved(editedPayloadJSON: #"{"a":2}"#, actor: "user")
        )
        let gated = try await ToolInvocationGuardrailApplying(hitl: hitl).apply(
            .confirmHITL(GuardrailHITLRequest()),
            for: event
        )
        XCTAssertEqual(gated.argumentsJSON, #"{"a":2}"#)
    }

    func test_contentApplying_chunk_softAllowsConfirm() {
        let chunk = AssistantChunkEvent(sessionID: "s", chunkIndex: 0, content: "mid")
        let out = AssistantContentGuardrailApplying().apply(
            .confirmHITL(GuardrailHITLRequest()),
            for: chunk
        )
        XCTAssertEqual(out, .allowed("mid"))
    }

    func test_contentApplying_completion_confirm() {
        let completion = AssistantCompletionEvent(sessionID: "s", fullCompletion: "full", chunkCount: 1)
        let out = AssistantContentGuardrailApplying().apply(
            .confirmHITL(GuardrailHITLRequest(requiredFields: ["review"])),
            for: completion
        )
        XCTAssertEqual(out, .confirm(content: "full", requiredFields: ["review"]))
    }
}
