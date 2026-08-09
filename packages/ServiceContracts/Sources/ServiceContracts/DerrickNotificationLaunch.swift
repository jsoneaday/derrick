import Foundation

/// CLI flags / cross-process wake for the host UI (main app only).
public enum DerrickNotificationLaunch: Sendable {
    public static let pollArgument = "--derrick-notify-poll"
    /// Present a job result panel: `--derrick-show-job-result <result-id>`
    public static let showJobResultArgument = "--derrick-show-job-result"
    /// Ask daemon to post a job-result notification: `--derrick-post-job-result-notify <result-id>`
    public static let postJobResultNotifyArgument = "--derrick-post-job-result-notify"
    /// Headless bootstrap to run due jobs while the interactive UI is quit.
    public static let jobWorkerArgument = "--derrick-job-worker"
    /// Distributed notification name (object = job result id).
    public static let showJobResultDistributedName = "derrick.ui.showJobResult"

    public static func isPollLaunch(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(pollArgument)
    }

    public static func isJobWorkerLaunch(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(jobWorkerArgument)
    }

    public static func jobResultIDToPresent(_ arguments: [String] = CommandLine.arguments) -> String? {
        guard let idx = arguments.firstIndex(of: showJobResultArgument) else { return nil }
        let next = arguments.index(after: idx)
        guard next < arguments.endIndex else { return nil }
        let id = arguments[next]
        return id.isEmpty ? nil : id
    }

    public static func jobResultIDToNotify(_ arguments: [String] = CommandLine.arguments) -> String? {
        guard let idx = arguments.firstIndex(of: postJobResultNotifyArgument) else { return nil }
        let next = arguments.index(after: idx)
        guard next < arguments.endIndex else { return nil }
        let id = arguments[next]
        return id.isEmpty ? nil : id
    }

    /// Panel-only session from notification tap argv.
    public static func isJobResultPresentationLaunch(_ arguments: [String] = CommandLine.arguments) -> Bool {
        jobResultIDToPresent(arguments) != nil
    }

    public static func postShowJobResult(_ id: String) {
        DerrickJobResultPresentationWake.post(resultID: id)
    }
}
