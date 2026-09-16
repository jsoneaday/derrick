import Foundation
import Structure

/// Removes leftover Derrick Docker containers from a previous crash or kill.
public enum DerrickDockerOrphanSweeper: Sendable {
    public enum Scope: Sendable {
        /// Every matching container, including running ones. Daemon crash recovery only.
        case allMatching
        /// Exited, dead, or created only. Safe at UI launch while jobs may still be running.
        case stoppedOnly
    }

    /// Best-effort: list by label and name prefix, then `docker rm -f`.
    /// Returns how many container IDs were passed to remove (0 if none or list failed).
    @discardableResult
    public static func sweep(
        executor: DockerCLIExecutor,
        scope: Scope = .allMatching
    ) async -> Int {
        var ids = Set<String>()
        let lists = switch scope {
        case .allMatching:
            DerrickDockerRuntimeIdentity.psListArguments
        case .stoppedOnly:
            DerrickDockerRuntimeIdentity.psStoppedListArguments
        }
        for arguments in lists {
            guard let result = try? await executor(arguments, Data(), 30),
                  result.exitCode == 0
            else {
                continue
            }
            ids.formUnion(parseContainerIDs(result.stdout))
        }
        let ordered = ids.sorted()
        guard !ordered.isEmpty else {
            return 0
        }
        _ = try? await executor(["rm", "-f"] + ordered, Data(), 60)
        return ordered.count
    }

    static func parseContainerIDs(_ stdout: Data) -> [String] {
        String(decoding: stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { id in
                !id.isEmpty && id.count >= 12 && id.allSatisfy(\.isHexDigit)
            }
    }
}
