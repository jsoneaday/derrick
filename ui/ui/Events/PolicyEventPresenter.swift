import Foundation
import Combine
import AppEvents
import PolicyUserInteraction

/// Main-actor UI bridge: listens on `AppEventBus` and drives a single ModalPopup.
@MainActor
final class PolicyEventPresenter: ObservableObject {
    static let shared = PolicyEventPresenter()

    @Published private(set) var activeEvent: PolicyUserEvent?
    @Published private(set) var isPresented: Bool = false

    private let bus: AppEventBus
    private var subscriptionID: UUID?
    private var queue: [PolicyUserEvent] = []
    private var isProcessing = false
    private var timeoutTask: Task<Void, Never>?

    private init(bus: AppEventBus = .shared) {
        self.bus = bus
    }

    func start() {
        guard subscriptionID == nil else { return }
        Task {
            let id = await bus.subscribe { [weak self = self] anyEvent in
                guard let policy = anyEvent.base as? PolicyUserEvent else { return }
                await MainActor.run {
                    self?.enqueue(policy)
                }
            }
            await MainActor.run {
                self.subscriptionID = id
            }
        }
    }

    func stop() {
        if let subscriptionID {
            Task { await bus.unsubscribe(subscriptionID) }
        }
        subscriptionID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        queue.removeAll()
        activeEvent = nil
        isPresented = false
        isProcessing = false
    }

    private func enqueue(_ event: PolicyUserEvent) {
        queue.append(event)
        queue.sort { $0.priority > $1.priority }
        processNextIfNeeded()
    }

    private func processNextIfNeeded() {
        guard !isProcessing, activeEvent == nil, let next = queue.first else { return }
        queue.removeFirst()
        isProcessing = true
        activeEvent = next
        isPresented = true
        debugLog("[policy-ui] present kind=\(next.kind.rawValue) source=\(next.source.rawValue) title=\(next.title)")

        if next.kind == .approvalRequired || next.kind == .networkAccessRequest || next.kind == .usageLimitRequest {
            let eventID = next.id
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await MainActor.run {
                    guard let self, self.activeEvent?.id == eventID else { return }
                    self.finish(decision: .timedOut)
                }
            }
        }
    }

    func dismissNotice() {
        finish(decision: .dismissed)
    }

    func approve(actor: String? = "ui-user") {
        finish(decision: .approved(actor: actor))
    }

    func approveOnce(actor: String? = "ui-user") {
        finish(decision: .approvedOnce(actor: actor))
    }

    func approveAlways(actor: String? = "ui-user") {
        finish(decision: .approvedPermanently(actor: actor))
    }

    func deny(actor: String? = "ui-user") {
        finish(decision: .denied(actor: actor))
    }

    private func finish(decision: PolicyUserDecision) {
        guard let event = activeEvent else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        let eventID = event.id
        let kind = event.kind
        activeEvent = nil
        isPresented = false
        isProcessing = false
        debugLog("[policy-ui] decision=\(String(describing: decision)) for \(eventID)")

        if kind == .approvalRequired || kind == .networkAccessRequest || kind == .usageLimitRequest {
            Task {
                await bus.completeDecision(id: eventID, decision: decision)
            }
        }
        // Notices/failures: fire-and-forget publish already delivered; no waiter.

        processNextIfNeeded()
    }
}
