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

    var currentStatus: String {
        for entry in entries.reversed().prefix(8) {
            let msg = entry.message.lowercased()
            if msg.contains("reviewer request started") {
                return "Reviewing script safety..."
            } else if msg.contains("sending request to xpc helper service") || msg.contains("xpc run request started") || msg.contains("running process inside") {
                return "Agent running containerized environment..."
            } else if msg.contains("executing tool: python_script_exec") {
                return "Agent executing script in sandbox..."
            } else if msg.contains("started formulating plan to:") || msg.contains("formulating plan (chunk") {
                var action = "analyze request"
                if let toRange = msg.range(of: "to: ") {
                    let rawPrompt = msg[toRange.upperBound...]
                    if rawPrompt.count > 45 {
                        action = String(rawPrompt.prefix(42)) + "..."
                    } else {
                        action = String(rawPrompt)
                    }
                }
                
                if let range = msg.range(of: "chunk "), let endRange = msg.range(of: ")...") {
                    let chunkStr = msg[range.upperBound..<endRange.lowerBound]
                    if let chunkVal = Int(chunkStr) {
                        let pct = min(99, Int(Double(chunkVal) / 7.5))
                        return "Agent generating script to \(action) (\(pct)%)..."
                    }
                }
                return "Agent generating script to \(action)..."
            } else if msg.contains("started generating final response") || msg.contains("generating final response (chunk") {
                if let range = msg.range(of: "chunk "), let endRange = msg.range(of: ")...") {
                    let chunkStr = msg[range.upperBound..<endRange.lowerBound]
                    if let chunkVal = Int(chunkStr) {
                        let pct = min(99, Int(Double(chunkVal) / 5.0))
                        return "Writing response (\(pct)%)..."
                    }
                }
                return "Writing response..."
            } else if msg.contains("prompt sent") || msg.contains("llm request") {
                return "Generating response..."
            } else if msg.contains("tool result received") {
                return "Processing tool results..."
            }
        }
        return "Thinking..."
    }

    func formattedTimestamp(for entry: DebugLogEntry) -> String {
        formatter.string(from: entry.timestamp)
    }
}

nonisolated func debugLog(_ message: String) {
    Task { @MainActor in
        DebugLogStore.shared.log(message)
    }
}
