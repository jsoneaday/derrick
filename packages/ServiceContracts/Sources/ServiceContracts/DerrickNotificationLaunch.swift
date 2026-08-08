import Foundation

/// CLI flags for waking the host UI to post user notifications (main app only).
public enum DerrickNotificationLaunch: Sendable {
    public static let pollArgument = "--derrick-notify-poll"

    public static func isPollLaunch(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(pollArgument)
    }
}
