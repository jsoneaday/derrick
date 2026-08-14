import Foundation
import Testing
@testable import ui

@Suite struct UsageLimitsTests {
    @Test func clampsToAbsoluteMax() {
        var limits = UsageLimits(
            maxToolRoundsPerMessage: 99,
            maxScriptRunsPerMessage: -1,
            maxReviewerCallsPerMessage: 50,
            dailyTokenBudget: 9_999_999,
            weeklyTokenBudget: -5
        )
        limits = limits.clamped()
        #expect(limits.maxToolRoundsPerMessage == UsageLimits.absoluteMax.maxToolRoundsPerMessage)
        #expect(limits.maxScriptRunsPerMessage == 0)
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

    @Test func usageLimitMetadataFiltersPresetsAboveCurrent() {
        let meta = UsageLimitRaiseMetadata(
            dimension: UsageLimitDimension.dailyTokens.rawValue,
            currentLimit: 200_000,
            sessionProposedLimit: 500_000,
            presets: UsageLimits.dailyTokenPresets,
            absoluteMax: UsageLimits.absoluteMax.dailyTokenBudget
        )
        #expect(meta.selectablePresets == [500_000, 1_000_000, 2_000_000])
    }

    @Test func usageLimitActorParsing() {
        #expect(UsageLimitRaiseOutcome.parseLimit(from: "ui-permanent:500000") == 500_000)
        #expect(UsageLimitRaiseOutcome.isPermanent(actor: "ui-permanent:500000"))
        #expect(!UsageLimitRaiseOutcome.isPermanent(actor: "ui-session:500000"))
    }
}
