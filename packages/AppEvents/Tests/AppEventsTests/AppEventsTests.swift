import Foundation
import Testing
@testable import AppEvents

private struct TestNotice: AppEvent {
    let id: UUID
    let createdAt: Date
    let priority: EventPriority
    let correlationId: String?
    let text: String

    init(text: String, priority: EventPriority = .normal, correlationId: String? = nil) {
        self.id = UUID()
        self.createdAt = Date()
        self.priority = priority
        self.correlationId = correlationId
        self.text = text
    }
}

private struct TestApproval: DecisionRequestingEvent {
    typealias Decision = String
    let id: UUID
    let createdAt: Date
    let priority: EventPriority
    let correlationId: String?

    init() {
        self.id = UUID()
        self.createdAt = Date()
        self.priority = .userDecision
        self.correlationId = "test"
    }
}

@Suite struct AppEventsTests {
    @Test func publishDeliversToSubscriber() async {
        let bus = AppEventBus()
        let box = Box()
        await bus.subscribe { event in
            if let notice = event.base as? TestNotice {
                await box.append(notice.text)
            }
        }
        await bus.publish(TestNotice(text: "hello"))
        let values = await box.values()
        #expect(values == ["hello"])
    }

    @Test func requestDecisionCompletesWhenUIResolves() async {
        let bus = AppEventBus()
        let event = TestApproval()
        await bus.subscribe { anyEvent in
            if anyEvent.id == event.id {
                await bus.completeDecision(id: event.id, decision: "approved")
            }
        }
        let decision = await bus.initDecision(event)
        #expect(decision == "approved")
    }
}

private actor Box {
    private var items: [String] = []
    func append(_ value: String) { items.append(value) }
    func values() -> [String] { items }
}
