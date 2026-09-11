import Foundation

public enum NewsWorkerBridge: Sendable {
    public typealias Runner = @Sendable (Data) async throws -> Data

    private final class Storage: @unchecked Sendable {
        var runner: Runner?
    }

    private static let storage = Storage()

    public static func install(_ runner: @escaping Runner) {
        storage.runner = runner
    }

    public static func run(requestJSON: Data) async throws -> Data {
        guard let runner = storage.runner else {
            throw NewsReaderError.workerUnavailable("Docker news reader is not ready yet.")
        }
        return try await runner(requestJSON)
    }
}

public struct BridgedNewsWorker: NewsWorkerRunning {
    public init() {}

    public func run(requestJSON: Data) async throws -> Data {
        try await NewsWorkerBridge.run(requestJSON: requestJSON)
    }
}
