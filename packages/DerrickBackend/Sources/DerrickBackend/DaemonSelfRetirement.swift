import Foundation
import Structure

/// Exits this daemon only when asked over XPC. Automatic on-disk binary watch is
/// disabled: exiting during UI connect leaves Mach XPC dead and bootstrap times out.
public enum DaemonSelfRetirement: Sendable {
    public static let launchedIdentity: DerrickDaemonBinaryIdentity? = {
        guard let path = Self.executablePath() else { return nil }
        return DerrickDaemonBinaryIdentity.snapshot(atPath: path)
    }()

    public static var launchedFingerprint: String? {
        launchedIdentity?.fingerprint
    }

    public static func install() {}

    public static func requestExit(reason: String) {
        fputs("[derrickd] retiring — \(reason)\n", stderr)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            _exit(1)
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
