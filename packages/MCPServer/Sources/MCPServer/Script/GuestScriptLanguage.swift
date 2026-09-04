import Foundation
import MCP

public enum GuestScriptLanguage: String, Sendable, Equatable {
    case python
    case swift

    public var verifierID: String {
        switch self {
        case .python:
            return "python-check-v1"
        case .swift:
            return "swift-check-v1"
        }
    }

    public static func resolve(arguments: [String: Value], script: String) -> GuestScriptLanguage {
        if let raw = arguments["language"]?.stringValue?.lowercased() {
            switch raw {
            case "python", "py":
                return .python
            case "swift":
                return .swift
            default:
                break
            }
        }
        if script.contains("import Foundation") || script.contains("import Swift") {
            return .swift
        }
        return .python
    }
}
