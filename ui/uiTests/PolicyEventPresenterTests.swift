import Foundation
import Testing
import AppEvents
import PolicyUserInteraction
@testable import ui

@Suite struct PolicyEventPresenterTests {
    @MainActor
    @Test func duplicateEnqueuePresentsOnceAndIgnoresLateTimeout() async throws {
        let bus = AppEventBus()
        let presenter = PolicyEventPresenter(bus: bus)
        presenter.start()
        // Wait for async subscribe.
        for _ in 0..<50 {
            if await bus.subscriberCount == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await bus.subscriberCount == 1)

        let event = PolicyUserEventFactory.egressAccessRequest(host: "www.apple.com")
        // Simulate double-subscription delivering the same event twice.
        async let decisionTask: PolicyUserDecision = bus.initDecision(event)
        // Manual second enqueue of the same id (as a buggy double handler would).
        try await Task.sleep(nanoseconds: 20_000_000)
        // Access enqueue via publish path only — re-deliver same boxed event by publishing.
        await bus.publish(event)

        // Allow presenter to process.
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(presenter.isPresented)
        #expect(presenter.activeEvent?.id == event.id)

        presenter.approveAlways(actor: "test-user")
        let decision = await decisionTask
        #expect(decision == .approvedPermanently(actor: "test-user"))
        #expect(!presenter.isPresented)

        // Late timeout must not re-open or re-complete.
        presenter.approveAlways(actor: "late")
        #expect(!presenter.isPresented)
        #expect(await bus.pendingDecisionCount == 0)
    }

    @MainActor
    @Test func startIsIdempotentAgainstRaces() async throws {
        let bus = AppEventBus()
        let presenter = PolicyEventPresenter(bus: bus)
        presenter.start()
        presenter.start()
        presenter.start()
        for _ in 0..<50 {
            if await bus.subscriberCount >= 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // At most one subscription.
        #expect(await bus.subscriberCount == 1)
        presenter.stop()
    }
}
