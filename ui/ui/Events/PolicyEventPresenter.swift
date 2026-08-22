import Foundation
import Combine
import AppEvents
import PolicyUserInteraction

/// Main-actor UI bridge: listens on `AppEventBus` and drives a single ModalPopup.
///
/// Invariants:
/// - At most one bus subscription (race-safe `start()`).
/// - Each event id is presented at most once (dedupe queue + finished set).
/// - `finish` is idempotent; late timeout tasks cannot re-fire a completed decision.
@MainActor
final class PolicyEventPresenter: ObservableObject {
    static let shared = PolicyEventPresenter()

    @Published private(set) var activeEvent: PolicyUserEvent?
    @Published private(set) var isPresented: Bool = false

    private let bus: AppEventBus
    private var subscriptionID: UUID?
    /// Set immediately in `start()` so concurrent callers do not double-subscribe.
    private var isStartingSubscription = false
    private var queue: [PolicyUserEvent] = []
    private var queuedIDs: Set<UUID> = []
    private var finishedIDs: Set<UUID> = []
    private var isProcessing = false
    private var timeoutTask: Task<Void, Never>?
    /// Bumped on every present/finish so stale timeout tasks exit even if cancel is late.
    private var presentationGeneration: UInt64 = 0

    /// Decision wait timeout for approval / network / usage modals.
    static let decisionTimeoutNanoseconds: UInt64 = 60_000_000_000

    /// - Parameter bus: Defaults to shared; tests may inject an isolated bus.
    init(bus: AppEventBus = .shared) {
        self.bus = bus
    }

    func start() {
        if subscriptionID != nil || isStartingSubscription { return }
        isStartingSubscription = true
        Task {
            let id = await bus.subscribe { [weak self] anyEvent in
                guard let policy = anyEvent.base as? PolicyUserEvent else { return }
                await MainActor.run {
                    self?.enqueue(policy)
                }
            }
            await MainActor.run {
                self.subscriptionID = id
                self.isStartingSubscription = false
            }
        }
    }

    func stop() {
        if let subscriptionID {
            Task { await bus.unsubscribe(subscriptionID) }
        }
        subscriptionID = nil
        isStartingSubscription = false
        timeoutTask?.cancel()
        timeoutTask = nil
        queue.removeAll()
        queuedIDs.removeAll()
        finishedIDs.removeAll()
        activeEvent = nil
        isPresented = false
        isProcessing = false
        presentationGeneration &+= 1
    }

    private func enqueue(_ event: PolicyUserEvent) {
        // Usage limits use a dedicated picker modal (presets + custom permanent value).
        if event.kind == .usageLimitRequest {
            Task { @MainActor in
                let outcome = await UsageLimitRaisePresenter.shared.present(event: event)
                await bus.completeDecision(id: event.id, decision: outcome.policyDecision)
            }
            return
        }
        // Already decided or already waiting in queue / active — never present twice.
        if finishedIDs.contains(event.id) {
            debugLog("[policy-ui] drop finished event id=\(event.id) kind=\(event.kind.rawValue)")
            return
        }
        if activeEvent?.id == event.id {
            debugLog("[policy-ui] drop active duplicate id=\(event.id)")
            return
        }
        if queuedIDs.contains(event.id) {
            debugLog("[policy-ui] drop queued duplicate id=\(event.id)")
            return
        }
        queue.append(event)
        queuedIDs.insert(event.id)
        queue.sort { $0.priority > $1.priority }
        processNextIfNeeded()
    }

    private func processNextIfNeeded() {
        guard !isProcessing, activeEvent == nil else { return }
        // Skip any stale finished ids (defensive).
        while let next = queue.first {
            queue.removeFirst()
            queuedIDs.remove(next.id)
            if finishedIDs.contains(next.id) {
                debugLog("[policy-ui] skip finished in queue id=\(next.id)")
                continue
            }
            present(next)
            return
        }
    }

    private func present(_ next: PolicyUserEvent) {
        isProcessing = true
        activeEvent = next
        isPresented = true
        presentationGeneration &+= 1
        let generation = presentationGeneration
        debugLog(
            "[policy-ui] present kind=\(next.kind.rawValue) source=\(next.source.rawValue) title=\(next.title) id=\(next.id)"
        )

        if next.kind == .approvalRequired
            || next.kind == .networkAccessRequest
            || next.kind == .usageLimitRequest
        {
            let eventID = next.id
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.decisionTimeoutNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    guard self.presentationGeneration == generation else { return }
                    guard self.activeEvent?.id == eventID else { return }
                    guard !self.finishedIDs.contains(eventID) else { return }
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
        // Idempotent: a late timeout must not complete after a real user decision.
        if finishedIDs.contains(event.id) {
            debugLog("[policy-ui] ignore late decision=\(String(describing: decision)) for \(event.id)")
            activeEvent = nil
            isPresented = false
            isProcessing = false
            return
        }
        finishedIDs.insert(event.id)
        timeoutTask?.cancel()
        timeoutTask = nil
        presentationGeneration &+= 1
        let eventID = event.id
        let kind = event.kind
        activeEvent = nil
        isPresented = false
        isProcessing = false
        debugLog("[policy-ui] decision=\(String(describing: decision)) for \(eventID)")

        // Bound growth of finished set (long sessions).
        if finishedIDs.count > 256 {
            finishedIDs.removeAll(keepingCapacity: true)
            finishedIDs.insert(eventID)
        }

        if kind == .approvalRequired || kind == .networkAccessRequest || kind == .usageLimitRequest {
            Task {
                await bus.completeDecision(id: eventID, decision: decision)
            }
        }

        processNextIfNeeded()
    }
}
