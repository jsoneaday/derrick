import Foundation

/// Owner identity for every Derrick-managed Docker container.
///
/// Used to label creates and to sweep leftovers on daemon Docker init.
public enum DerrickDockerRuntimeIdentity: Sendable {
    public static let labelKey = "app.derrick"
    public static let labelValue = "runtime"
    public static let labelAssignment = "\(labelKey)=\(labelValue)"

    /// `docker create --label app.derrick=runtime …`
    public static let createLabelArguments = ["--label", labelAssignment]

    /// Name prefixes for current and unlabeled leftover containers.
    public static let namePrefixes = [
        "derrick-web-crawler",
        "derrick-news-reader",
        "derrick-guest-runtime",
        "derrick-swift-runtime",
        "derrick-file-extractor",
    ]

    public static let psLabelFilterArguments = [
        "ps", "-aq", "--filter", "label=\(labelAssignment)",
    ]

    public static func psNameFilterArguments(prefix: String) -> [String] {
        ["ps", "-aq", "--filter", "name=\(prefix)"]
    }

    /// All `docker ps` argv forms the orphan sweeper is allowed to issue.
    public static var psListArguments: [[String]] {
        [psLabelFilterArguments] + namePrefixes.map(psNameFilterArguments)
    }

    public static func isAllowedPsFilter(_ filter: String) -> Bool {
        if filter == "label=\(labelAssignment)" {
            return true
        }
        return namePrefixes.contains { filter == "name=\($0)" }
    }

    public static func createHasRuntimeLabel(_ dockerArgs: [String]) -> Bool {
        let args = Array(dockerArgs.dropFirst())
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--label",
               index + 1 < args.count,
               args[index + 1] == labelAssignment {
                return true
            }
            if arg == "--label=\(labelAssignment)" {
                return true
            }
            index += 1
        }
        return false
    }
}
