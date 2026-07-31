import Foundation
import Combine
import DBRepository
import AppEvents
import PolicyUserInteraction
import LLMAgentClient

/// Permanent usage limits (Settings) + session raises + daily/weekly token counters.
@MainActor
final class UsageLimitsService: ObservableObject {
    static let shared = UsageLimitsService()

    static let limitsConfigKey = "usageLimits.v1"
    static let countersConfigKey = "usageTokenCounters.v1"

    @Published private(set) var permanentLimits: UsageLimits = .default
    @Published private(set) var counters: UsageTokenCounters = .empty()
    /// Running estimated USD for the current day/week (from token × list prices).
    @Published private(set) var estimatedUSDToday: Double = 0
    @Published private(set) var estimatedUSDThisWeek: Double = 0

    /// Session-only raises (never written as permanent unless user edits Settings).
    private var sessionToolRounds: Int?
    private var sessionPythonRuns: Int?
    private var sessionReviewerCalls: Int?
    private var sessionDailyTokens: Int?
    private var sessionWeeklyTokens: Int?

    /// Per-user-message counters (reset each stream).
    private(set) var messageToolRounds = 0
    private(set) var messagePythonRuns = 0
    private(set) var messageReviewerCalls = 0

    private var repository: DBRepository?
    private let username = "ui"
    private let password = "ui"

    private init() {}

    func configure(repository: DBRepository) async {
        self.repository = repository
        await reload()
    }

    func reload() async {
        guard let repository else { return }
        if let raw = try? await repository.loadConfig(key: Self.limitsConfigKey, username: username, password: password),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(UsageLimits.self, from: data) {
            permanentLimits = decoded.clamped()
        } else {
            permanentLimits = .default
        }
        if let raw = try? await repository.loadConfig(key: Self.countersConfigKey, username: username, password: password),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(UsageTokenCounters.self, from: data) {
            counters = decoded
            counters.rollIfNeeded()
        } else {
            counters = .empty()
        }
    }

    func savePermanentLimits(_ limits: UsageLimits) async {
        let clamped = limits.clamped()
        permanentLimits = clamped
        guard let repository else { return }
        do {
            let data = try JSONEncoder().encode(clamped)
            if let json = String(data: data, encoding: .utf8) {
                try await repository.saveConfig(key: Self.limitsConfigKey, value: json, username: username, password: password)
            }
        } catch {
            debugLog("Failed to save usage limits: \(error.localizedDescription)")
        }
    }

    func resetMessageCounters() {
        messageToolRounds = 0
        messagePythonRuns = 0
        messageReviewerCalls = 0
    }

    // MARK: - Effective caps (session raise wins if higher)

    var effectiveMaxToolRounds: Int {
        max(permanentLimits.maxToolRoundsPerMessage, sessionToolRounds ?? 0)
    }

    var effectiveMaxPythonRuns: Int {
        max(permanentLimits.maxPythonScriptRunsPerMessage, sessionPythonRuns ?? 0)
    }

    var effectiveMaxReviewerCalls: Int {
        max(permanentLimits.maxReviewerCallsPerMessage, sessionReviewerCalls ?? 0)
    }

    var effectiveDailyTokenBudget: Int {
        let p = permanentLimits.dailyTokenBudget
        let s = sessionDailyTokens ?? 0
        if p == 0 && s == 0 { return 0 }
        return max(p, s)
    }

    var effectiveWeeklyTokenBudget: Int {
        let p = permanentLimits.weeklyTokenBudget
        let s = sessionWeeklyTokens ?? 0
        if p == 0 && s == 0 { return 0 }
        return max(p, s)
    }

    // MARK: - Checks with optional session raise prompt

    /// Call at the start of each agent tool round (0-based round index about to run tools after model).
    func allowToolRound(roundIndex: Int) async -> Bool {
        let limit = effectiveMaxToolRounds
        // rounds used so far; allowing roundIndex means we need roundIndex < limit for 0..<limit
        if roundIndex < limit {
            messageToolRounds = roundIndex + 1
            return true
        }
        return await offerSessionRaise(
            dimension: .toolRounds,
            currentEffective: limit,
            presets: UsageLimits.toolRoundPresets,
            absoluteMax: UsageLimits.absoluteMax.maxToolRoundsPerMessage,
            applySession: { self.sessionToolRounds = $0 }
        ) && roundIndex < effectiveMaxToolRounds
    }

    func allowPythonScriptRun() async -> Bool {
        let limit = effectiveMaxPythonRuns
        if messagePythonRuns < limit {
            messagePythonRuns += 1
            return true
        }
        let raised = await offerSessionRaise(
            dimension: .pythonScripts,
            currentEffective: limit,
            presets: UsageLimits.pythonRunPresets,
            absoluteMax: UsageLimits.absoluteMax.maxPythonScriptRunsPerMessage,
            applySession: { self.sessionPythonRuns = $0 }
        )
        if raised, messagePythonRuns < effectiveMaxPythonRuns {
            messagePythonRuns += 1
            return true
        }
        return false
    }

    func allowReviewerCall() async -> Bool {
        let limit = effectiveMaxReviewerCalls
        if messageReviewerCalls < limit {
            messageReviewerCalls += 1
            return true
        }
        let raised = await offerSessionRaise(
            dimension: .reviewerCalls,
            currentEffective: limit,
            presets: UsageLimits.reviewerPresets,
            absoluteMax: UsageLimits.absoluteMax.maxReviewerCallsPerMessage,
            applySession: { self.sessionReviewerCalls = $0 }
        )
        if raised, messageReviewerCalls < effectiveMaxReviewerCalls {
            messageReviewerCalls += 1
            return true
        }
        return false
    }

    /// Prefer this when the provider returned `AgentTokenUsage` from the API.
    func recordAPIUsage(_ usage: AgentTokenUsage, pricing: ModelTokenPricing? = nil) async -> Bool {
        let units = max(usage.totalTokens, usage.promptTokens + usage.completionTokens)
        if let pricing {
            let usd = pricing.estimateUSD(usage: usage)
            addEstimatedUSD(usd)
        }
        debugLog(
            "Usage tokens source=\(usage.source.rawValue) prompt=\(usage.promptTokens) completion=\(usage.completionTokens) total=\(units)"
        )
        return await recordTokenUnits(units)
    }

    /// Fallback when the API did not report usage.
    func recordTokens(
        promptText: String,
        completionText: String,
        pricing: ModelTokenPricing? = nil
    ) async -> Bool {
        let usage = AgentTokenUsage.estimated(fromText: promptText, completion: completionText)
        return await recordAPIUsage(usage, pricing: pricing)
    }

    func recordTokenUnits(_ units: Int) async -> Bool {
        let added = max(0, units)
        counters.rollIfNeeded()
        // Roll estimated $ when the calendar bucket rolls (simple: reset day/week with counters).
        if counters.dayTokens == 0 {
            estimatedUSDToday = 0
        }
        counters.dayTokens += added
        counters.weekTokens += added
        await persistCounters()

        if !(await ensureTokenBudget(dimension: .dailyTokens, used: counters.dayTokens, effective: effectiveDailyTokenBudget, presets: UsageLimits.dailyTokenPresets, absoluteMax: UsageLimits.absoluteMax.dailyTokenBudget, applySession: { self.sessionDailyTokens = $0 })) {
            return false
        }
        if !(await ensureTokenBudget(dimension: .weeklyTokens, used: counters.weekTokens, effective: effectiveWeeklyTokenBudget, presets: UsageLimits.weeklyTokenPresets, absoluteMax: UsageLimits.absoluteMax.weeklyTokenBudget, applySession: { self.sessionWeeklyTokens = $0 })) {
            return false
        }
        return true
    }

    private func addEstimatedUSD(_ usd: Double) {
        counters.rollIfNeeded()
        estimatedUSDToday += usd
        estimatedUSDThisWeek += usd
    }

    private func ensureTokenBudget(
        dimension: UsageLimitDimension,
        used: Int,
        effective: Int,
        presets: [Int],
        absoluteMax: Int,
        applySession: (Int) -> Void
    ) async -> Bool {
        // 0 = disabled
        guard effective > 0 else { return true }
        if used <= effective { return true }
        // Over budget: offer raise; if raised enough to cover, ok.
        let raised = await offerSessionRaise(
            dimension: dimension,
            currentEffective: effective,
            presets: presets,
            absoluteMax: absoluteMax,
            applySession: applySession
        )
        guard raised else { return false }
        let newEffective: Int = {
            switch dimension {
            case .dailyTokens: return effectiveDailyTokenBudget
            case .weeklyTokens: return effectiveWeeklyTokenBudget
            default: return effective
            }
        }()
        return newEffective == 0 || used <= newEffective
    }

    private func offerSessionRaise(
        dimension: UsageLimitDimension,
        currentEffective: Int,
        presets: [Int],
        absoluteMax: Int,
        applySession: (Int) -> Void
    ) async -> Bool {
        guard let next = UsageLimits.nextPreset(above: currentEffective, in: presets, absoluteMax: absoluteMax) else {
            await presentHardStop(dimension: dimension, currentEffective: currentEffective)
            return false
        }
        let event = PolicyUserEventFactory.usageLimitExceeded(
            dimensionTitle: dimension.title,
            currentLimit: currentEffective,
            proposedSessionLimit: next,
            detail: usageSnapshotDetail(dimension: dimension)
        )
        let decision = await AppEventBus.shared.initDecision(event)
        switch decision {
        case .approved, .approvedOnce, .approvedPermanently:
            applySession(next)
            debugLog("Usage limit session raise \(dimension.rawValue): \(currentEffective) → \(next)")
            return true
        case .denied, .dismissed, .timedOut:
            debugLog("Usage limit stop \(dimension.rawValue) at \(currentEffective)")
            return false
        }
    }

    private func presentHardStop(dimension: UsageLimitDimension, currentEffective: Int) async {
        let event = PolicyUserEventFactory.usageLimitHardStop(
            dimensionTitle: dimension.title,
            currentLimit: currentEffective
        )
        await AppEventBus.shared.publish(event)
    }

    private func usageSnapshotDetail(dimension: UsageLimitDimension) -> String {
        switch dimension {
        case .toolRounds:
            return "This message has used \(messageToolRounds) tool round(s)."
        case .pythonScripts:
            return "This message has used \(messagePythonRuns) python_script_exec run(s)."
        case .reviewerCalls:
            return "This message has used \(messageReviewerCalls) security review(s)."
        case .dailyTokens:
            return "Today ≈ \(counters.dayTokens) tokens (approx)."
        case .weeklyTokens:
            return "This week ≈ \(counters.weekTokens) tokens (approx)."
        }
    }

    private func persistCounters() async {
        guard let repository else { return }
        do {
            let data = try JSONEncoder().encode(counters)
            if let json = String(data: data, encoding: .utf8) {
                try await repository.saveConfig(key: Self.countersConfigKey, value: json, username: username, password: password)
            }
        } catch {
            debugLog("Failed to save usage counters: \(error.localizedDescription)")
        }
    }
}
