import Foundation
import Structure

/// Runs the Docker news reader in MCPService where the egress proxy can bind.
struct MCPServiceNewsWorker: NewsWorkerRunning {
    func run(requestJSON: Data) async throws -> Data {
        _ = try await MCPServiceClient.shared.ensureUpAndHealth(retries: 2)
        let result = try await MCPServiceClient.shared.runNewsReader(requestJSON: requestJSON)
        guard result.ok else {
            let detail = result.message.nilIfEmpty
                ?? String(decoding: result.stderr, as: UTF8.self).nilIfEmpty
                ?? "News reader failed."
            throw NewsReaderError.workerUnavailable(detail)
        }
        return result.stdout
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
