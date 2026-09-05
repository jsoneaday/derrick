import Foundation
import Structure
import Testing
@testable import ui

@Suite(.serialized)
struct ExecutionContextRegistryTests {
    @Test func concurrentContextsDoNotStomp() {
        let registry = ExecutionContextRegistry.shared
        registry.resetForTesting()
        defer { registry.resetForTesting() }

        let contextA = ExecutionContextID(sessionID: "session-a", agentID: "ui")
        let contextB = ExecutionContextID(sessionID: "session-b", agentID: "ui")

        registry.install(contextA, slots: ExecutionContextSlots(apiKey: "key-a"))
        registry.install(contextB, slots: ExecutionContextSlots(apiKey: "key-b"))

        #expect(registry.slots(for: contextA)?.apiKey == "key-a")
        #expect(registry.slots(for: contextB)?.apiKey == "key-b")

        registry.remove(contextA)
        #expect(registry.slots(for: contextA) == nil)
        #expect(registry.slots(for: contextB)?.apiKey == "key-b")
    }

    @Test func unambiguousFallbackRequiresSingleActiveSession() {
        let registry = ExecutionContextRegistry.shared
        registry.resetForTesting()
        defer { registry.resetForTesting() }

        #expect(registry.slotsWhenUnambiguous() == nil)

        let only = ExecutionContextID(sessionID: "solo", agentID: "ui")
        registry.install(only, slots: ExecutionContextSlots(apiKey: "solo-key"))
        #expect(registry.slotsWhenUnambiguous()?.apiKey == "solo-key")

        let second = ExecutionContextID(sessionID: "other", agentID: "ui")
        registry.install(second, slots: ExecutionContextSlots(apiKey: "other-key"))
        #expect(registry.slotsWhenUnambiguous() == nil)
    }

    @Test func derivedWorkerContextsDoNotReplaceSessionActive() {
        let registry = ExecutionContextRegistry.shared
        registry.resetForTesting()
        defer { registry.resetForTesting() }

        let parent = ExecutionContextID(sessionID: "s1", agentID: "ui")
        let worker = ExecutionContextID(sessionID: "s1", agentID: "worker-a")
        registry.install(parent, slots: ExecutionContextSlots(apiKey: "parent-key"))
        registry.installDerived(worker, from: parent)

        #expect(registry.slots(for: worker)?.apiKey == "parent-key")
        #expect(registry.slots(forSession: "s1")?.apiKey == "parent-key")

        registry.removeDerived(worker)
        #expect(registry.slots(for: worker) == nil)
        #expect(registry.slots(for: parent)?.apiKey == "parent-key")
    }
}
