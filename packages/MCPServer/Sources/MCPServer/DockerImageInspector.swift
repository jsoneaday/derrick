import Foundation
import Structure

/// Reads and verifies pinned Docker product image digests.
public enum DockerImageInspector: Sendable {
    public static func localImageID(
        tag: String,
        executor: @escaping DockerCLIExecutor
    ) async throws -> DockerImageDigest {
        let response = try await executor(
            ["image", "inspect", "--format", "{{.Id}}", tag],
            Data(),
            30
        )
        guard response.exitCode == 0 else {
            throw DockerImageDigestError.imageMissing(tag)
        }
        let raw = String(decoding: response.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let digest = DockerImageDigest(hexDigest: raw) else {
            throw DockerImageDigestError.imageMissing(tag)
        }
        return digest
    }

    public static func verifyPinned(
        tag: String,
        expected: DockerImageDigest,
        executor: @escaping DockerCLIExecutor
    ) async throws {
        let actual = try await localImageID(tag: tag, executor: executor)
        guard actual == expected else {
            throw DockerImageDigestError.digestMismatch(tag: tag, expected: expected, actual: actual)
        }
    }

    /// Returns false when the image exists but predates required worker binaries (e.g. news reader).
    public static func workerImageHasCurrentBinaries(
        tag: String = DockerWorkerRuntime.image,
        executor: @escaping DockerCLIExecutor
    ) async -> Bool {
        let format = "{{index .Config.Labels \"\(DockerWorkerRuntime.binariesLabelKey)\"}}"
        do {
            let response = try await executor(
                ["image", "inspect", "--format", format, tag],
                Data(),
                30
            )
            guard response.exitCode == 0 else { return false }
            let label = String(decoding: response.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return label == DockerWorkerRuntime.binariesLabelValue
        } catch {
            return false
        }
    }
}
