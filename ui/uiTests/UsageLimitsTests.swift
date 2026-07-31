import Foundation
import Testing
@testable import ui

@Suite struct UsageLimitsTests {
    @Test func clampsToAbsoluteMax() {
        var limits = UsageLimits(
            maxToolRoundsPerMessage: 99,
            maxPythonScriptRunsPerMessage: -1,
            maxReviewerCallsPerMessage: 50,
            dailyTokenBudget: 9_999_999,
            weeklyTokenBudget: -5
        )
        limits = limits.clamped()
        #expect(limits.maxToolRoundsPerMessage == UsageLimits.absoluteMax.maxToolRoundsPerMessage)
        #expect(limits.maxPythonScriptRunsPerMessage == 0)
        #expect(limits.maxReviewerCallsPerMessage == UsageLimits.absoluteMax.maxReviewerCallsPerMessage)
        #expect(limits.dailyTokenBudget == UsageLimits.absoluteMax.dailyTokenBudget)
        #expect(limits.weeklyTokenBudget == 0)
    }

    @Test func defaultTokenBudgetsMatchProduct() {
        #expect(UsageLimits.default.dailyTokenBudget == 200_000)
        #expect(UsageLimits.default.weeklyTokenBudget == 1_000_000)
        #expect(UsageLimits.absoluteMax.dailyTokenBudget == 2_000_000)
        #expect(UsageLimits.absoluteMax.weeklyTokenBudget == 10_000_000)
    }

    @Test func nextPresetStepsUp() {
        #expect(UsageLimits.nextPreset(above: 3, in: UsageLimits.toolRoundPresets, absoluteMax: 10) == 5)
        #expect(UsageLimits.nextPreset(above: 10, in: UsageLimits.toolRoundPresets, absoluteMax: 10) == nil)
    }

    @Test func tokenApproxIsPositive() {
        #expect(UsageLimits.approximateTokenCount(for: "hello world") >= 1)
    }

    @Test func countersRollDay() {
        var c = UsageTokenCounters(dayKey: "2000-01-01", dayTokens: 42, weekKey: "2000-W01", weekTokens: 99)
        c.rollIfNeeded(now: Date())
        #expect(c.dayKey != "2000-01-01")
        #expect(c.dayTokens == 0)
    }
}
