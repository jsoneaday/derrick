import Foundation
import Structure

/// Process-wide structured log fan-out: stderr, optional SQLite persistence, live UI hooks.
public actor ServiceLogRecorder {
    public static let shared = ServiceLogRecorder()

    private var repository: DBRepository?
    private var liveHandlers: [@Sendable (ServiceLogEntry) -> Void] = []

    private init() {}

    public func configure(repository: DBRepository) {
        self.repository = repository
    }

    public func addLiveHandler(_ handler: @escaping @Sendable (ServiceLogEntry) -> Void) {
        liveHandlers.append(handler)
    }

    public func record(
        service: String,
        level: ServiceLogLevel = .info,
        code: String? = nil,
        message: String,
        detailJSON: String? = nil,
        createdAt: Date = .now,
        echoToStderr: Bool = true
    ) async {
        let entry = ServiceLogEntry(
            service: service,
            level: level,
            code: code,
            message: message,
            detailJSON: detailJSON,
            createdAt: createdAt
        )
        emit(entry, echoToStderr: echoToStderr)
        guard let repository else { return }
        do {
            try await repository.appendServiceLog(entry)
        } catch {
            fputs("[ServiceLogRecorder] persist failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func emit(_ entry: ServiceLogEntry, echoToStderr: Bool) {
        if echoToStderr {
            let codeSuffix = entry.code.map { " [\($0)]" } ?? ""
            fputs("[\(entry.service)]\(codeSuffix) \(entry.message)\n", stderr)
            if let detailJSON = entry.detailJSON, !detailJSON.isEmpty {
                fputs("  detail: \(detailJSON)\n", stderr)
            }
        }
        let handlers = liveHandlers
        for handler in handlers {
            handler(entry)
        }
    }
}
