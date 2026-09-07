import Foundation

/// UI used to kill JobKeepAlive before XPC connect; that raced Mach and hung bootstrap.
enum DaemonBootstrapCoordinator {
    static func prepareForHostApp(force: Bool = false) async throws {
        _ = force
        fputs("[DaemonHygiene] prepare skipped — do not kill helper on UI launch\n", stderr)
    }
}
