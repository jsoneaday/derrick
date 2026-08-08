import Foundation

/// Shared limits for session memory reads (tool + automatic retrieval).
public enum MemoryQueryPolicy: Sendable {
    /// Default retention window when `includeArchived` is false.
    public static let retentionMonths = 6

    /// Hard cap on rows returned per request, regardless of caller `limit`.
    public static let maxRowsPerRequest = 100

    public static func clampedRowLimit(_ requested: Int) -> Int {
        min(max(requested, 1), maxRowsPerRequest)
    }

    /// When `includeArchived` is false, records older than this cutoff are excluded.
    public static func retentionCutoff(includeArchived: Bool, now: Date = .now, calendar: Calendar = .current) -> Date? {
        guard !includeArchived else { return nil }
        return calendar.date(byAdding: .month, value: -retentionMonths, to: now)
    }

    public static func isWithinRetention(
        _ createdAt: Date,
        includeArchived: Bool,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        guard let cutoff = retentionCutoff(includeArchived: includeArchived, now: now, calendar: calendar) else {
            return true
        }
        return createdAt >= cutoff
    }
}
