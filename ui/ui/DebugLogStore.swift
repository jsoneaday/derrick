import DBRepository
import Foundation
import Combine
import Structure

/// In-memory ring buffer for live debug UI; persistence goes through `ServiceLogRecorder`.
@MainActor
final class DebugLogStore: ObservableObject {
    static let shared = DebugLogStore()

    @Published private(set) var entries: [ServiceLogEntry] = []

    private let formatter: DateFormatter
    private let maximumEntries = 2_000
    private var entryIDs: Set<String> = []

    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        self.formatter = formatter
    }

    private var liveConfigured = false

    func configureLiveUpdates() {
        guard !liveConfigured else { return }
        liveConfigured = true
        Task {
            await ServiceLogRecorder.shared.addLiveHandler { [weak self] entry in
                Task { @MainActor in
                    self?.append(entry)
                }
            }
        }
    }

    func append(_ entry: ServiceLogEntry) {
        guard entryIDs.insert(entry.id).inserted else { return }
        entries.append(entry)
        trimIfNeeded()
    }

    func replaceAll(_ entries: [ServiceLogEntry]) {
        self.entries = entries
        entryIDs = Set(entries.map(\.id))
        trimIfNeeded()
    }

    func mergePersisted(_ persisted: [ServiceLogEntry]) {
        var merged = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for entry in persisted {
            merged[entry.id] = entry
        }
        entries = merged.values.sorted { $0.createdAt < $1.createdAt }
        entryIDs = Set(entries.map(\.id))
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        guard entries.count > maximumEntries else { return }
        let overflow = entries.count - maximumEntries
        for old in entries.prefix(overflow) {
            entryIDs.remove(old.id)
        }
        entries.removeFirst(overflow)
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
