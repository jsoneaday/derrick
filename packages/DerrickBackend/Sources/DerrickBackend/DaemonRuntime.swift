import DBRepository
import Foundation
import ServiceContracts
import UserNotifications

/// In-process module registry for the headless daemon.
public enum DaemonModuleID: String, Sendable, CaseIterable {
    case events
    case notifications
    case jobs
    case agent
    case mcp
}

/// Owns shared SQLite, AppEventBus, and module lifecycle for `derrickd`.
public actor DaemonRuntime {
    public static let shared = DaemonRuntime()

    private var repository: DBRepository?
    private var readyModules: Set<DaemonModuleID> = [.events, .notifications]
    private var started = false

    public init() {}

    /// Optional hook set by JobKeepAlive to start MCP/Agent/Jobs in-process.
    nonisolated(unsafe) public static var onBootstrapModules: (@Sendable () async -> Void)?

    public func bootstrap() async throws -> DerrickDaemonBootstrapResult {
        if !started {
            try await openDatabase()
            // Defer notification prep and HITL polling so Mach bootstrap replies immediately.
            Task {
                await NotificationPostingService.shared.prepare()
                HITLApprovalPollService.shared.start()
            }
            // Job/Agent/MCP now run in-process — no UI job-worker wake.
            await DaemonJobWatchdog.shared.stop()
            started = true
            // Start modules in the background so Mach XPC bootstrap replies immediately.
            // Awaiting MCP↔Docker verify here hung UI ensureDaemon (leaked XPC continuations).
            if let onBootstrapModules = Self.onBootstrapModules {
                Task { await onBootstrapModules() }
            }
            fputs("[derrickd] runtime bootstrap ok modules=\(readyModules.map(\.rawValue).sorted())\n", stderr)
        }
        let path = try await repository?.databaseURL.path
        return DerrickDaemonBootstrapResult(
            ok: true,
            databasePath: path,
            message: "ok",
            modules: readyModules.map(\.rawValue).sorted()
        )
    }

    public func health() async -> ServiceHealthReport {
        let ok = started && repository != nil
        return ServiceHealthReport(
            service: .daemon,
            status: ok ? .ok : .degraded,
            detail: ok ? nil : "not bootstrapped",
            guestRuntimeImage: DerrickGuestRuntime.dockerImage,
            executableFingerprint: DaemonSelfRetirement.launchedFingerprint
        )
    }

    public func markModuleReady(_ id: DaemonModuleID) {
        readyModules.insert(id)
    }

    public func sharedRepository() async throws -> DBRepository {
        if let repository { return repository }
        try await openDatabase()
        guard let repository else {
            throw DaemonRuntimeError.databaseUnavailable
        }
        return repository
    }

    public func postNotification(_ request: UserNotificationRequest) async throws {
        try await NotificationPostingService.shared.post(request)
    }

    private func openDatabase() async throws {
        let directory = try DerrickAppSupport.databaseDirectory()
        let config = DBRepositoryConfiguration(
            applicationName: DerrickAppSupport.defaultApplicationName,
            databaseName: "derrick",
            databaseDirectoryURL: directory,
            username: "ui",
            password: "ui"
        )
        let repo = DBRepository(configuration: config)
        _ = try await repo.createEmptyDatabaseIfNeeded(username: "ui", password: "ui")
        repository = repo
        fputs("[derrickd] DB \(await repo.databaseURL.path)\n", stderr)
    }
}

public enum DaemonRuntimeError: Error, LocalizedError, Sendable {
    case databaseUnavailable

    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable: return "Daemon database unavailable"
        }
    }
}
