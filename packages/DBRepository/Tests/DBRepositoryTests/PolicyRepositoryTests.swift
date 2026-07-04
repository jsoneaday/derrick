import XCTest
@testable import DBRepository
@testable import MemorySystem

final class PolicyRepositoryTests: XCTestCase {
    var repository: DBRepository!
    let testAppName = "TestApp"

    override func setUp() async throws {
        let tempDir = NSTemporaryDirectory()
        let tempDB = "\(tempDir)test_policy_\(UUID().uuidString).db"
        let config = DBRepositoryConfiguration(
            applicationName: testAppName,
            databaseName: "test_policy",
            databaseDirectoryURL: URL(fileURLWithPath: tempDir),
            username: "test",
            password: "test"
        )
        repository = DBRepository(configuration: config)
    }

    func test_savePolicyRule_and_loadPolicyRules() async throws {
        let rule = PolicyRule(
            applicationName: testAppName,
            name: "Block file_write",
            scope: "tool_call",
            matcherJSON: #"{"tool_name": "file_write"}"#,
            outcomeJSON: #"{"action": "deny"}"#,
            priority: 50,
            enabled: true
        )

        try await repository.saveRule(rule)

        let loaded = try await repository.loadRules(applicationName: testAppName, scope: "tool_call")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, rule.id)
        XCTAssertEqual(loaded[0].name, "Block file_write")
        XCTAssertEqual(loaded[0].priority, 50)
        XCTAssertTrue(loaded[0].enabled)
    }

    func test_loadPolicyRules_respectsPriority() async throws {
        let rule1 = PolicyRule(
            applicationName: testAppName,
            name: "Low priority",
            scope: "tool_call",
            matcherJSON: "{}",
            outcomeJSON: "{}",
            priority: 10,
            enabled: true
        )
        let rule2 = PolicyRule(
            applicationName: testAppName,
            name: "High priority",
            scope: "tool_call",
            matcherJSON: "{}",
            outcomeJSON: "{}",
            priority: 100,
            enabled: true
        )

        try await repository.saveRule(rule1)
        try await repository.saveRule(rule2)

        let loaded = try await repository.loadRules(applicationName: testAppName, scope: "tool_call")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "High priority")
        XCTAssertEqual(loaded[1].name, "Low priority")
    }

    func test_loadPolicyRules_ignoresDisabledRules() async throws {
        let rule1 = PolicyRule(
            applicationName: testAppName,
            name: "Enabled",
            scope: "tool_call",
            matcherJSON: "{}",
            outcomeJSON: "{}",
            enabled: true
        )
        let rule2 = PolicyRule(
            applicationName: testAppName,
            name: "Disabled",
            scope: "tool_call",
            matcherJSON: "{}",
            outcomeJSON: "{}",
            enabled: false
        )

        try await repository.saveRule(rule1)
        try await repository.saveRule(rule2)

        let loaded = try await repository.loadRules(applicationName: testAppName, scope: "tool_call")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Enabled")
    }

    func test_savePolicyApproval_and_loadPolicyApprovals() async throws {
        let sessionID = UUID().uuidString
        let approval = PolicyApproval(
            applicationName: testAppName,
            sessionID: sessionID,
            ruleID: "rule-123",
            requestType: "tool_call",
            requestPayloadJSON: #"{"tool": "read_file", "path": "/etc/passwd"}"#,
            editedPayloadJSON: #"{"tool": "read_file", "path": "/home/user/config.txt"}"#,
            decision: "confirmed",
            actor: "user@example.com"
        )

        try await repository.saveApproval(approval)

        let loaded = try await repository.loadApprovals(sessionID: sessionID, limit: 10)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].decision, "confirmed")
        XCTAssertEqual(loaded[0].actor, "user@example.com")
        XCTAssertNotNil(loaded[0].editedPayloadJSON)
    }

    func test_logPolicyAuditEntry() async throws {
        let sessionID = UUID().uuidString
        let entry = PolicyAuditLogEntry(
            applicationName: testAppName,
            sessionID: sessionID,
            eventType: "tool_call_blocked",
            scope: "tool_call",
            requestJSON: #"{"tool": "shell_exec", "cmd": "rm -rf /"}"#,
            decision: "denied",
            reason: "Dangerous system command"
        )

        try await repository.logAuditEntry(entry)

        let log = try await repository.auditLog(sessionID: sessionID, limit: 10, page: 1)
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].eventType, "tool_call_blocked")
        XCTAssertEqual(log[0].decision, "denied")
    }

    func test_auditLog_pagination() async throws {
        let sessionID = UUID().uuidString

        for i in 0..<25 {
            let entry = PolicyAuditLogEntry(
                applicationName: testAppName,
                sessionID: sessionID,
                eventType: "test_event",
                scope: "test_scope",
                requestJSON: #"{"index": \#(i)}"#,
                decision: "allowed"
            )
            try await repository.logAuditEntry(entry)
        }

        let page1 = try await repository.auditLog(sessionID: sessionID, limit: 10, page: 1)
        XCTAssertEqual(page1.count, 10)

        let page2 = try await repository.auditLog(sessionID: sessionID, limit: 10, page: 2)
        XCTAssertEqual(page2.count, 10)

        let page3 = try await repository.auditLog(sessionID: sessionID, limit: 10, page: 3)
        XCTAssertEqual(page3.count, 5)
    }

    func test_auditLog_orderedNewestFirst() async throws {
        let sessionID = UUID().uuidString
        var entryIDs: [String] = []

        for _ in 0..<3 {
            let entry = PolicyAuditLogEntry(
                applicationName: testAppName,
                sessionID: sessionID,
                eventType: "test",
                scope: "test",
                requestJSON: "{}",
                decision: "allowed"
            )
            try await repository.logAuditEntry(entry)
            entryIDs.append(entry.id)
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let log = try await repository.auditLog(sessionID: sessionID, limit: 10, page: 1)
        XCTAssertEqual(log[0].id, entryIDs[2])
        XCTAssertEqual(log[1].id, entryIDs[1])
        XCTAssertEqual(log[2].id, entryIDs[0])
    }

    func test_ruleUpdate() async throws {
        var rule = PolicyRule(
            applicationName: testAppName,
            name: "Original",
            scope: "tool_call",
            matcherJSON: "{}",
            outcomeJSON: "{}",
            priority: 50,
            enabled: true
        )

        try await repository.saveRule(rule)

        rule.enabled = false
        try await repository.saveRule(rule)

        let loaded = try await repository.loadRules(applicationName: testAppName, scope: "tool_call")
        XCTAssertEqual(loaded.count, 0)
    }

    func test_multipleApplicationsIsolated() async throws {
        let rule1 = PolicyRule(
            applicationName: "App1",
            name: "App1 rule",
            scope: "tool_call",
            matcherJSON: "{}",
            outcomeJSON: "{}",
            enabled: true
        )
        let rule2 = PolicyRule(
            applicationName: "App2",
            name: "App2 rule",
            scope: "tool_call",
            matcherJSON: "{}",
            outcomeJSON: "{}",
            enabled: true
        )

        try await repository.saveRule(rule1)
        try await repository.saveRule(rule2)

        let loadedForApp1 = try await repository.loadRules(applicationName: "App1", scope: "tool_call")
        XCTAssertEqual(loadedForApp1.count, 1)
        XCTAssertEqual(loadedForApp1[0].name, "App1 rule")
    }
}
