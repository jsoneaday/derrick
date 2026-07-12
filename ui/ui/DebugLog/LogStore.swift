import Foundation
import Combine
import OSLog

/// A thread-safe, observable store for log messages.
@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    
    func log(_ message: String, category: String = "default") {
        let entry = LogEntry(message: message, category: category)
        entries.append(entry)
        // Keep the log from growing indefinitely
        if entries.count > 500 {
            entries.removeFirst(100)
        }
    }
}

struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp = Date()
    let message: String
    let category: String
}
