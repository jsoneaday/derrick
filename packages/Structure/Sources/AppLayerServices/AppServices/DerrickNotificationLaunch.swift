import Foundation

/// CLI flags / cross-process wake for the host UI (main app only).
public enum DerrickNotificationLaunch: Sendable {
    /// Present a job result panel: `--derrick-show-job-result <result-id>`
    public static let showJobResultArgument = "--derrick-show-job-result"
    /// Present a HITL Allow/Deny sheet: `--derrick-show-hitl-approval <approval-id>`
    public static let showHITLApprovalArgument = "--derrick-show-hitl-approval"

    public static func jobResultIDToPresent(_ arguments: [String] = CommandLine.arguments) -> String? {
        guard let idx = arguments.firstIndex(of: showJobResultArgument) else { return nil }
        let next = arguments.index(after: idx)
        guard next < arguments.endIndex else { return nil }
        let id = arguments[next]
        return id.isEmpty ? nil : id
    }

    /// Panel-only session from notification tap argv or pending app-group wake file.
    public static func isJobResultPresentationLaunch(_ arguments: [String] = CommandLine.arguments) -> Bool {
        jobResultIDToPresent(arguments) != nil
    }

    /// Launch should present a job result without mounting the main chat shell.
    /// Uses argv and the pending wake file (argv is often dropped by Launch Services).
    public static func hasJobResultPresentationIntent(_ arguments: [String] = CommandLine.arguments) -> Bool {
        isJobResultPresentationLaunch(arguments) || DerrickJobResultPresentationWake.peekPendingResultID() != nil
    }

    public static func hitlApprovalIDToPresent(_ arguments: [String] = CommandLine.arguments) -> String? {
        guard let idx = arguments.firstIndex(of: showHITLApprovalArgument) else { return nil }
        let next = arguments.index(after: idx)
        guard next < arguments.endIndex else { return nil }
        let id = arguments[next]
        return id.isEmpty ? nil : id
    }

    public static func isHITLApprovalPresentationLaunch(_ arguments: [String] = CommandLine.arguments) -> Bool {
        hitlApprovalIDToPresent(arguments) != nil
    }

    public static func hasHITLApprovalPresentationIntent(_ arguments: [String] = CommandLine.arguments) -> Bool {
        isHITLApprovalPresentationLaunch(arguments)
            || DerrickHITLApprovalPresentationWake.peekPendingApprovalID() != nil
    }

    public static func postShowJobResult(_ id: String) {
        DerrickJobResultPresentationWake.post(resultID: id)
    }

    public static func postShowHITLApproval(_ id: String) {
        DerrickHITLApprovalPresentationWake.post(approvalID: id)
    }
}
