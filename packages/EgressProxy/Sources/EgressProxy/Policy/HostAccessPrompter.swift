import Foundation

/// User decision for a host that is not yet on the permanent/session allowlist.
public enum HostAccessUserDecision: Sendable, Equatable {
    case allowOnce
    case allowAlways
    case deny
}

/// Asks the controlling app (via reverse XPC) whether an unknown host may be reached.
/// Used mid-flight when CONNECT targets a host preflight did not cover.
public protocol HostAccessPrompter: Sendable {
    func requestAccess(host: String) async -> HostAccessUserDecision
}

/// Always denies (tests / offline helper without an app peer).
public struct DenyingHostAccessPrompter: HostAccessPrompter {
    public init() {}

    public func requestAccess(host: String) async -> HostAccessUserDecision {
        .deny
    }
}

/// Coalesces concurrent prompts for the same host and applies a timeout.
public actor CoalescingHostAccessPrompter {
    private let underlying: any HostAccessPrompter
    private let timeoutNanoseconds: UInt64
    private var inFlight: [String: Task<HostAccessUserDecision, Never>] = [:]

    public init(underlying: any HostAccessPrompter, timeoutSeconds: UInt64 = 120) {
        self.underlying = underlying
        self.timeoutNanoseconds = timeoutSeconds * 1_000_000_000
    }

    public func requestAccess(host: String) async -> HostAccessUserDecision {
        let key = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let existing = inFlight[key] {
            return await existing.value
        }
        let underlying = self.underlying
        let timeoutNanoseconds = self.timeoutNanoseconds
        let task = Task<HostAccessUserDecision, Never> {
            await withTaskGroup(of: HostAccessUserDecision.self) { group in
                group.addTask {
                    await underlying.requestAccess(host: key)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return .deny
                }
                let first = await group.next() ?? .deny
                group.cancelAll()
                return first
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }
}

/// Sendable wrapper so `DefaultDestinationPolicy` can hold the coalescing actor.
public struct CoalescingHostAccessPrompterBox: HostAccessPrompter {
    private let prompter: CoalescingHostAccessPrompter

    public init(underlying: any HostAccessPrompter, timeoutSeconds: UInt64 = 120) {
        self.prompter = CoalescingHostAccessPrompter(underlying: underlying, timeoutSeconds: timeoutSeconds)
    }

    public func requestAccess(host: String) async -> HostAccessUserDecision {
        await prompter.requestAccess(host: host)
    }
}
