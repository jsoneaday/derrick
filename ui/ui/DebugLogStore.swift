import Foundation
import Combine

struct DebugLogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

/// Stores logs in memory in order to display in UI
@MainActor
final class DebugLogStore: ObservableObject {
    static let shared = DebugLogStore()

    @Published private(set) var entries: [DebugLogEntry] = []

    private let formatter: DateFormatter
    private let maximumEntries = 200

    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm:ss a"
        self.formatter = formatter
    }

    @MainActor
    func log(_ message: String) {
        entries.append(DebugLogEntry(timestamp: Date(), message: message))
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
    }

    func formattedTimestamp(for entry: DebugLogEntry) -> String {
        formatter.string(from: entry.timestamp)
    }
}


