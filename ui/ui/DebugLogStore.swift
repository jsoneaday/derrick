import Foundation
import Combine

struct DebugLogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

final class DebugLogStore: ObservableObject {
    static let shared = DebugLogStore()

    @Published private(set) var entries: [DebugLogEntry] = []

    private let formatter: DateFormatter
    private let maximumEntries = 200

    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
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

@MainActor
func debugLog(_ message: String) {
    DebugLogStore.shared.log(message)
}
