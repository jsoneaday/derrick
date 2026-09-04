import DBRepository
import Foundation
import Combine
import ServiceContracts

/// In-memory ring buffer for live debug UI; persistence goes through `ServiceLogRecorder`.
@MainActor
final class DebugLogStore: ObservableObject {
    static let shared = DebugLogStore()

    @Published private(set) var entries: [ServiceLogEntry] = []

    private let formatter: DateFormatter
    private let maximumEntries = 2_000

    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        self.formatter = formatter
    }

    func configureLiveUpdates() {
        Task {
            await ServiceLogRecorder.shared.addLiveHandler { [weak self] entry in
                Task { @MainActor in
                    self?.append(entry)
                }
            }
        }
    }

    func append(_ entry: ServiceLogEntry) {
        if entries.contains(where: { $0.id == entry.id }) {
            return
        }
        entries.append(entry)
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
    }

    func replaceAll(_ entries: [ServiceLogEntry]) {
        self.entries = entries
    }

    func mergePersisted(_ persisted: [ServiceLogEntry]) {
        var merged = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for entry in persisted {
            merged[entry.id] = entry
        }
        entries = merged.values.sorted { $0.createdAt < $1.createdAt }
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
    }

    @MainActor
    func log(_ message: String, code: String? = "panel", level: ServiceLogLevel = .debug) {
        Task {
            await ServiceLogRecorder.shared.record(
                service: DerrickServiceID.ui.shortName,
                level: level,
                code: code,
                message: message
            )
        }
    }

    func formattedTimestamp(for entry: ServiceLogEntry) -> String {
        formatter.string(from: entry.createdAt)
    }

    func displayLine(for entry: ServiceLogEntry) -> String {
        let level = entry.level.uppercased()
        let code = entry.code.map { "[\($0)] " } ?? ""
        var line = "[\(formattedTimestamp(for: entry))] [\(entry.service)] [\(level)] \(code)\(entry.message)"
        if let detailJSON = entry.detailJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detailJSON.isEmpty {
            line += "\n  \(detailJSON)"
        }
        return line
    }

    var fullText: String {
        entries.map(displayLine(for:)).joined(separator: "\n")
    }
}
