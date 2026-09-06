import Foundation
import Structure

/// Removes leftover Derrick Docker containers from a previous crash or kill.
///
/// Call from daemon Docker sync — not a one-off on the developer machine, not on
/// UI launch (the daemon may still be running jobs), and not on UI quit.
public enum DerrickDockerOrphanSweeper: Sendable {
    /// Best-effort: list by label and name prefix, then `docker rm -f`.
    /// Returns how many container IDs were passed to remove (0 if none or list failed).
    @discardableResult
    public static func sweep(executor: DockerCLIExecutor) async -> Int {
        var ids = Set<String>()
        for arguments in DerrickDockerRuntimeIdentity.psListArguments {
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
