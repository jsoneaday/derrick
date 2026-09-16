import Foundation
import Structure

/// Drops untagged worker images left after a rebuild. Never removes the live tag.
public enum DerrickDockerDanglingImagePruner: Sendable {
    @discardableResult
    public static func prune(executor: DockerCLIExecutor) async -> Bool {
        let arguments = DockerWorkerRuntime.danglingImagePruneArguments
        guard let result = try? await executor(arguments, Data(), 60) else {
            return false
        }
        return result.exitCode == 0
    }
}
