import Foundation

/// Permanent usage limits (Settings). Session bumps may raise effective values until the app quits.
struct UsageLimits: Codable, Equatable, Sendable {
    var maxToolRoundsPerMessage: Int
    var maxScriptRunsPerMessage: Int
    var maxReviewerCallsPerMessage: Int
    /// Provider-reported (or estimated) tokens per local calendar day. `0` = disabled.
    var dailyTokenBudget: Int
    /// Provider-reported (or estimated) tokens per week. `0` = disabled.
    var weeklyTokenBudget: Int

    static let `default` = UsageLimits(
        maxToolRoundsPerMessage: 3,
        maxScriptRunsPerMessage: 3,
        maxReviewerCallsPerMessage: 3,
        dailyTokenBudget: 200_000,
        weeklyTokenBudget: 1_000_000
    )

    /// Hard ceilings for permanent Settings and session raises.
    static let absoluteMax = UsageLimits(
        maxToolRoundsPerMessage: 10,
        maxScriptRunsPerMessage: 10,
        maxReviewerCallsPerMessage: 10,
        dailyTokenBudget: 2_000_000,
        weeklyTokenBudget: 10_000_000
    )

    enum CodingKeys: String, CodingKey {
        case maxToolRoundsPerMessage
        case maxScriptRunsPerMessage
        case maxReviewerCallsPerMessage
        case dailyTokenBudget
        case weeklyTokenBudget
    }

    init(
        maxToolRoundsPerMessage: Int,
        maxScriptRunsPerMessage: Int,
        maxReviewerCallsPerMessage: Int,
        dailyTokenBudget: Int,
        weeklyTokenBudget: Int
    ) {
        self.maxToolRoundsPerMessage = maxToolRoundsPerMessage
        self.maxScriptRunsPerMessage = maxScriptRunsPerMessage
        self.maxReviewerCallsPerMessage = maxReviewerCallsPerMessage
        self.dailyTokenBudget = dailyTokenBudget
        self.weeklyTokenBudget = weeklyTokenBudget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxToolRoundsPerMessage = try container.decode(Int.self, forKey: .maxToolRoundsPerMessage)
        maxScriptRunsPerMessage = try container.decode(Int.self, forKey: .maxScriptRunsPerMessage)
        maxReviewerCallsPerMessage = try container.decode(Int.self, forKey: .maxReviewerCallsPerMessage)
        dailyTokenBudget = try container.decode(Int.self, forKey: .dailyTokenBudget)
        weeklyTokenBudget = try container.decode(Int.self, forKey: .weeklyTokenBudget)
    }

    static let toolRoundPresets = [3, 5, 8, 10]
    static let scriptRunPresets = [3, 5, 8, 10]
    static let reviewerPresets = [3, 5, 8, 10]
    static let dailyTokenPresets = [50_000, 100_000, 200_000, 500_000, 1_000_000, 2_000_000]
    static let weeklyTokenPresets = [250_000, 500_000, 1_000_000, 2_500_000, 5_000_000, 10_000_000]

    func clamped() -> UsageLimits {
        UsageLimits(
            maxToolRoundsPerMessage: Self.clamp(maxToolRoundsPerMessage, min: 1, max: Self.absoluteMax.maxToolRoundsPerMessage),
            maxScriptRunsPerMessage: Self.clamp(maxScriptRunsPerMessage, min: 0, max: Self.absoluteMax.maxScriptRunsPerMessage),
            maxReviewerCallsPerMessage: Self.clamp(maxReviewerCallsPerMessage, min: 0, max: Self.absoluteMax.maxReviewerCallsPerMessage),
            dailyTokenBudget: Self.clamp(dailyTokenBudget, min: 0, max: Self.absoluteMax.dailyTokenBudget),
            weeklyTokenBudget: Self.clamp(weeklyTokenBudget, min: 0, max: Self.absoluteMax.weeklyTokenBudget)
        )
    }

    private static func clamp(_ value: Int, min: Int, max: Int) -> Int {
        Swift.min(Swift.max(value, min), max)
    }

    static func approximateTokenCount(for text: String) -> Int {
        max(1, (text.utf8.count + 3) / 4)
    }

    /// Next preset strictly above `current`, capped at absolute max; nil if already at max.
    static func nextPreset(above current: Int, in presets: [Int], absoluteMax: Int) -> Int? {
        let sorted = presets.sorted()
        if let next = sorted.first(where: { $0 > current }) {
            return min(next, absoluteMax)
        }
        if current < absoluteMax {
            return absoluteMax
        }
        return nil
    }
}

enum UsageLimitDimension: String, Sendable, Codable, CaseIterable {
    case toolRounds
    case scriptRuns
    case reviewerCalls
    case dailyTokens
    case weeklyTokens

    var title: String {
        switch self {
        case .toolRounds: return "Tool rounds"
        case .scriptRuns: return "Script runs"
        case .reviewerCalls: return "Security reviews"
        case .dailyTokens: return "Daily token budget"
        case .weeklyTokens: return "Weekly token budget"
        }
    }
}

/// Persistent token counters with day/week buckets.
struct UsageTokenCounters: Codable, Equatable, Sendable {
    var dayKey: String
    var dayTokens: Int
    var weekKey: String
    var weekTokens: Int

    static func empty(now: Date = .now, calendar: Calendar = .current) -> UsageTokenCounters {
        UsageTokenCounters(
            dayKey: Self.dayKey(for: now, calendar: calendar),
            dayTokens: 0,
            weekKey: Self.weekKey(for: now, calendar: calendar),
            weekTokens: 0
        )
    }

    mutating func rollIfNeeded(now: Date = .now, calendar: Calendar = .current) {
        let d = Self.dayKey(for: now, calendar: calendar)
        let w = Self.weekKey(for: now, calendar: calendar)
        if d != dayKey {
            dayKey = d
            dayTokens = 0
        }
        if w != weekKey {
            weekKey = w
            weekTokens = 0
        }
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// ISO week-based key (year-week) for a stable weekly bucket.
    static func weekKey(for date: Date, calendar: Calendar = .current) -> String {
        var cal = calendar
        cal.firstWeekday = 2
        let year = cal.component(.yearForWeekOfYear, from: date)
        let week = cal.component(.weekOfYear, from: date)
        return String(format: "%04d-W%02d", year, week)
    }
}
