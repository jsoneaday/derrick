import Foundation
import ServiceContracts

/// Exits this daemon when the on-disk executable is no longer the one we launched.
/// launchd `KeepAlive` then execs the replacement. Do not `bootout` for a rebuild.
public enum DaemonSelfRetirement: Sendable {
    private static let pollNanoseconds: UInt64 = 5_000_000_000
    private static let confirmNanoseconds: UInt64 = 1_500_000_000

    public static let launchedIdentity: DerrickDaemonBinaryIdentity? = {
        guard let path = Self.executablePath() else { return nil }
        return DerrickDaemonBinaryIdentity.snapshot(atPath: path)
    }()

    public static var launchedFingerprint: String? {
        launchedIdentity?.fingerprint
    }

    public static func install() {
        guard let launched = launchedIdentity, let path = executablePath() else {
            fputs("[derrickd] self-retirement skipped — cannot snapshot executable\n", stderr)
            return
        }
        fputs(
            "[derrickd] self-retirement watching \(path) fingerprint=\(launched.fingerprint)\n",
            stderr
        )
        Task { await watch(path: path, launched: launched) }
    }

    public static func requestExit(reason: String) {
        fputs("[derrickd] retiring — \(reason)\n", stderr)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exit(0)
        }
    }

    private static func watch(path: String, launched: DerrickDaemonBinaryIdentity) async {
        while true {
            try? await Task.sleep(nanoseconds: pollNanoseconds)
            guard let onDisk = DerrickDaemonBinaryIdentity.snapshot(atPath: path) else {
                continue
            }
            guard onDisk != launched else { continue }
            try? await Task.sleep(nanoseconds: confirmNanoseconds)
            guard let confirmed = DerrickDaemonBinaryIdentity.snapshot(atPath: path),
                  confirmed != launched,
                  FileManager.default.isExecutableFile(atPath: path)
            else {
                continue
            }
            requestExit(
                reason: "on-disk binary changed \(launched.fingerprint) → \(confirmed.fingerprint)"
            )
            return
        }
    }

    private static func executablePath() -> String? {
        if let url = Bundle.main.executableURL {
            return url.resolvingSymlinksInPath().path
        }
        guard !CommandLine.arguments.isEmpty else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }
}
