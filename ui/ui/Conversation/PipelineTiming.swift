import Foundation

/// Lightweight wall-clock spans for prompt→final bottleneck analysis.
/// All emitted lines start with `[TIME_METRIC]` so they can be grepped in the debug log.
enum PipelineTiming {
    static let prefix = "[TIME_METRIC]"

    static func elapsedMS(from start: Date, to end: Date = Date()) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000.0).rounded()))
    }

    static func log(_ line: String) {
        let body = line.hasPrefix(prefix) ? line : "\(prefix) \(line)"
        debugLog(body)
    }
}
