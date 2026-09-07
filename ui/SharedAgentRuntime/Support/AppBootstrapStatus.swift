import Foundation
import Combine
import Structure

/// App-load initialization progress and failures for the bootstrap modal.
@MainActor
final class AppBootstrapStatus: ObservableObject {
    static let shared = AppBootstrapStatus()

    enum Phase: String, Sendable, Equatable {
        case idle
        case loadingSession
        case connectingHelper
        case checkingDocker
        case preparingImage
        case verifyingEnvironment
        case ready
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusMessage: String = "Starting…"
    @Published private(set) var failureTitle: String?
    @Published private(set) var failureMessage: String?
    /// Extra recovery control on the failure modal (for example Open Login Items).
    @Published private(set) var failureRecovery: FailureRecovery = .none
    /// When true, modal is visible (in progress or failure awaiting dismiss).
    @Published private(set) var isModalPresented: Bool = false

    /// Single-flight handle so concurrent SwiftUI `.task` entries join one bootstrap.
    private var inFlightBootstrap: Task<Void, Never>?

    private init() {}

    /// Run client bootstrap once; concurrent callers await the same flight.
    /// After cancel, a later caller may start a new flight (modal was cleared).
    ///
    /// When bootstrap already finished, `body` still runs so a recreated `ContentView`
    /// can sync local `@State` (`sessionReady`, `helperModelSettings`, etc.).
    /// Callers that only **joined** an in-flight flight must also run `body` once ready.
    func runClientBootstrap(_ body: @escaping @MainActor () async -> Void) async {
        if phase == .ready {
            await body()
            return
        }

        var ranBodyInFlight = false

        if let existing = inFlightBootstrap {
            await existing.value
        } else {
            ranBodyInFlight = true
            let task = Task { @MainActor in
                await body()
            }
            inFlightBootstrap = task
            await task.value
            inFlightBootstrap = nil
        }

        if phase == .ready, !ranBodyInFlight {
            await body()
        }
    }

    var isInitializing: Bool {
        switch phase {
        case .idle, .ready, .failed:
            return false
        default:
            return true
        }
    }

    var showsProgressIndicator: Bool {
        isInitializing
    }

    /// Start bootstrap UI. Idempotent while initializing; no-ops after ready
    /// (SwiftUI may re-enter `.task` — must not re-open an undismissable modal).
    @discardableResult
    func beginLoadingSession() -> Bool {
        if phase == .ready {
            debugLog("[bootstrap] beginLoadingSession ignored (already ready)")
            return false
        }
        if isInitializing {
            debugLog("[bootstrap] beginLoadingSession ignored (already initializing)")
            return false
        }
        phase = .loadingSession
        statusMessage = "Loading session store…"
        failureTitle = nil
        failureMessage = nil
        failureRecovery = .none
        isModalPresented = true
        DerrickAppSupport.clearUIBootstrapReadyMarker()
        debugLog("[bootstrap] phase=\(phase.rawValue) \(statusMessage)")
        return true
    }

    func update(phase: Phase, message: String) {
        // Never re-open the modal after ready (parallel service ensure-up must not reflash it).
        if self.phase == .ready, phase != .failed, phase != .ready {
            debugLog("[bootstrap] ignore phase=\(phase.rawValue) (already ready): \(message)")
            return
        }
        // Don't let a cancelled re-entrant task demote ready via failed paths above.
        self.phase = phase
        self.statusMessage = message
        isModalPresented = true
        debugLog("[bootstrap] phase=\(phase.rawValue) \(message)")
    }

    func markReady() {
        phase = .ready
        statusMessage = "Ready"
        failureTitle = nil
        failureMessage = nil
        failureRecovery = .none
        isModalPresented = false
        DerrickUISessionPresence.markInteractiveSessionActive()
        DerrickAppSupport.writeUIBootstrapReadyMarker()
        debugLog("[bootstrap] phase=ready")
    }

    func markFailed(
        title: String,
        message: String,
        technicalDetail: String? = nil,
        recovery: FailureRecovery = .none
    ) {
        // Never replace a successful ready state with a late failure from a racing task.
        if phase == .ready {
            debugLog("[bootstrap] markFailed ignored (already ready): \(title) \(message)")
            return
        }
        phase = .failed
        statusMessage = message
        failureTitle = title
        failureMessage = message
        failureRecovery = recovery
        isModalPresented = true
        if let technicalDetail, !technicalDetail.isEmpty {
            debugLog("[bootstrap] FAILED title=\(title) user_message=\(message) detail=\(technicalDetail)")
        } else {
            debugLog("[bootstrap] FAILED title=\(title) user_message=\(message)")
        }
    }

    /// SwiftUI cancelled the bootstrap task — clear modal if we never reached ready
    /// so a later `.task` entry can run again (do not leave an undismissable overlay).
    /// Also used by Try Again after a failure so `beginLoadingSession` can start a new flight.
    func noteBootstrapCancelled() {
        guard phase != .ready else { return }
        phase = .idle
        statusMessage = "Starting…"
        failureTitle = nil
        failureMessage = nil
        failureRecovery = .none
        isModalPresented = false
        debugLog("[bootstrap] cancelled — modal cleared for retry")
    }

    func dismissFailure() {
        guard phase == .failed else { return }
        isModalPresented = false
        debugLog("[bootstrap] failure modal dismissed")
    }

    enum FailureRecovery: Equatable, Sendable {
        case none
        case retryDaemon
        case openLoginItems
    }

    struct ClassifiedFailure: Equatable, Sendable {
        var title: String
        var message: String
        var recovery: FailureRecovery = .none
    }

    /// Maps prewarm / Docker errors into a short title and user-facing explanation.
    static func classifyError(_ error: Error) -> ClassifiedFailure {
        if let agentError = error as? JobServiceLoginAgent.AgentError {
            return classifyDaemonAgentError(agentError)
        }
        let ns = error as NSError
        let text = ns.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        if lower.contains("docker desktop is required")
            || lower.contains("executable file not found")
            || ns.code == 127
            || lower.contains("no such file") && lower.contains("docker") {
            return ClassifiedFailure(
                title: "Docker Desktop Required",
                message: "Docker Desktop does not appear to be installed or the docker command is not available. Install Docker Desktop, open it once, then restart Derrick."
            )
        }
        if lower.contains("cannot connect to the docker daemon")
            || lower.contains("connect to the docker daemon")
            || lower.contains("error during connect")
            || lower.contains("docker.sock")
            || lower.contains("is the docker daemon running") {
            return ClassifiedFailure(
                title: "Docker Desktop Not Running",
                message: "Docker Desktop is installed but not running, or Derrick cannot reach the Docker engine. Start Docker Desktop, wait until it is idle, then restart Derrick."
            )
        }
        if lower.contains("timed out") || lower.contains("xpc call timed out") {
            return ClassifiedFailure(
                title: "Background Service Did Not Respond",
                message: "Derrick started its background service but could not talk to it. Quit Derrick, then open it again."
            )
        }
        if lower.contains("xpc") && (lower.contains("unavailable") || lower.contains("interrupted") || lower.contains("invalidat")) {
            return ClassifiedFailure(
                title: "Helper Service Unavailable",
                message: "The Docker helper service failed to start. Restart Derrick. If this continues, reinstall the app or check Console logs for DockerRunnerHelper."
            )
        }
        if lower.contains("failed to pull")
            || lower.contains("guest runtime image is unavailable")
            || lower.contains("swift runtime image is unavailable") {
            return ClassifiedFailure(
                title: "Environment Image Setup Failed",
                message: "Derrick could not download the guest runtime image. Check your network connection and that Docker Desktop has enough disk space, then try again."
            )
        }
        if lower.contains("docker image build failed")
            || lower.contains("derrick-web-crawler")
            || lower.contains("#0 building")
            || lower.contains("could not build the web crawler") {
            return ClassifiedFailure(
                title: "Website Crawl Is Still Setting Up",
                message: "You can chat now. Website crawl will work after Docker finishes preparing it. Make sure Docker Desktop is running and has enough disk space."
            )
        }
        if lower.contains("invalid reference format") {
            return ClassifiedFailure(
                title: "Container Setup Failed",
                message: "Derrick could not create or start its secure runtime containers. Open Docker Desktop and confirm it is running, then restart Derrick. Details are in the debug log."
            )
        }
        if lower.contains("swift environment check") {
            return ClassifiedFailure(
                title: "Environment Verification Failed",
                message: "The runtime started but failed a basic Swift environment check. Rebuild may help after updating Docker Desktop. See the debug log for technical details."
            )
        }
        if lower.contains("could not replace its background service")
            || lower.contains("leftover derrick")
            || lower.contains("previous runtime") {
            return backgroundServiceRetryFailure()
        }
        if lower.contains("login items approval")
            || lower.contains("smappservice") && lower.contains("operation not permitted") {
            return backgroundServiceDidNotStartFailure()
        }
        if lower.contains("daemon registration failed")
            || lower.contains("failed to register derrick daemon")
            || lower.contains("launchctl bootstrap") {
            return backgroundServiceRetryFailure()
        }
        let trimmed = text.isEmpty ? "An unknown error occurred during startup." : text
        return ClassifiedFailure(
            title: "Initialization Failed",
            message: "Derrick could not finish setting up its runtime environment.\n\n\(trimmed)\n\nSee the debug log for more detail, then restart Derrick after fixing the issue."
        )
    }

    private static func classifyDaemonAgentError(
        _ error: JobServiceLoginAgent.AgentError
    ) -> ClassifiedFailure {
        switch error {
        case .needsLoginItemsApproval:
            return backgroundServiceDidNotStartFailure()
        case .registerFailed:
            return backgroundServiceRetryFailure()
        case .missingPlist, .missingExecutable:
            return ClassifiedFailure(
                title: "Background Service Did Not Start",
                message: "Derrick is missing its background service. Quit Derrick and open it again. If this continues, reinstall the app."
            )
        }
    }

    /// Session LaunchAgent failed. Retry in-app — do not send people to Login Items
    /// unless macOS actually reports `.requiresApproval`.
    static func backgroundServiceRetryFailure() -> ClassifiedFailure {
        ClassifiedFailure(
            title: "Background Service Did Not Start",
            message: """
            Derrick could not start its background service. This is not a Slack or plugin problem — the helper that talks to connectors did not come up.

            Tap Try Again. If it still fails, quit Derrick completely and open it once more.
            """,
            recovery: .retryDaemon
        )
    }

    /// Copy for first-time Login Items approval only.
    /// macOS does not show an in-app prompt after Derrick has been listed once.
    static func backgroundServiceDidNotStartFailure() -> ClassifiedFailure {
        ClassifiedFailure(
            title: "Background Service Needs Permission",
            message: """
            macOS is blocking Derrick’s background helper. Open System Settings → General → Login Items, find Derrick under Background App Activity, turn it on, then tap Try Again.
            """,
            recovery: .openLoginItems
        )
    }
}
