import Foundation

/// CLI flags / cross-process wake for the host UI (main app only).
public enum DerrickNotificationLaunch: Sendable {
    public static let pollArgument = "--derrick-notify-poll"
    /// Present a job result panel: `--derrick-show-job-result <result-id>`
    public static let showJobResultArgument = "--derrick-show-job-result"

    public static func isPollLaunch(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(pollArgument)
    }

    public static func jobResultIDToPresent(_ arguments: [String] = CommandLine.arguments) -> String? {
        guard let idx = arguments.firstIndex(of: showJobResultArgument) else { return nil }
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
