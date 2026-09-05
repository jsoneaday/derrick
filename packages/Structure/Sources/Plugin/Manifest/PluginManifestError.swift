import Foundation

public enum PluginManifestError: Error, Equatable, LocalizedError {
    case invalidJSON
    case notAnObject
    case missingSchema
    case unsupportedSchema(String)
    case missingName
    case invalidName(String)
    case invalidSecretField(String)
    case invalidRole(String)
    case invalidAuthor
    case invalidFieldType(String)
    case invalidEntrypoint(String)
    case pathNotRelative(String)
    case pathEscapesRoot(String)
    case missingRuntime
    case missingFile(String)
    case unknownAuthProvider(String)
    case invalidAuthRefName(String)
    case invalidTriggerPrefix(String)
    case intervalTooShort(Int)
    case invalidDependency(String)
    case invalidContentHash(String)
    case invalidSkill(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "plugin.json is not valid JSON"
        case .notAnObject:
            return "plugin.json must be a JSON object"
        case .missingSchema:
            return "plugin.json is missing $schema"
        case .unsupportedSchema(let s):
            return "Unsupported Agent Plugins schema: \(s)"
        case .missingName:
            return "plugin.json is missing name"
        case .invalidName(let n):
            return "Invalid plugin name '\(n)'. Use lowercase letters, numbers, hyphens, and dots (for example slack-connection)."
        case .invalidSecretField(let n):
            return "Invalid plugin secret field: \(n)"
        case .invalidRole(let r):
            return "Invalid plugin role '\(r)'. Use connector or omit the field."
        case .invalidAuthor:
            return "plugin.json author is invalid"
        case .invalidFieldType(let f):
            return "plugin.json field has the wrong type: \(f)"
        case .invalidEntrypoint(let p):
            return "Entrypoint must be a plugin-relative .py path: \(p)"
        case .pathNotRelative(let p):
            return "Path must be plugin-relative and start with ./: \(p)"
        case .pathEscapesRoot(let p):
            return "Path escapes the plugin root: \(p)"
        case .missingRuntime:
            return "app.derrick runtime.json is required for a handle plugin"
        case .missingFile(let p):
            return "Missing plugin file: \(p)"
        case .unknownAuthProvider(let p):
            return "Unknown auth provider: \(p)"
        case .invalidAuthRefName(let n):
            return "Invalid auth_ref name: \(n)"
        case .invalidTriggerPrefix(let p):
            return "Invalid message_in_room prefix: \(p)"
        case .intervalTooShort(let s):
            return "Schedule interval must be at least \(PluginContract.minScheduleIntervalSeconds)s (got \(s))"
        case .invalidDependency(let n):
            return "Swift plugin dependencies are not supported: \(n)"
        case .invalidContentHash(let h):
            return "Invalid content hash: \(h)"
        case .invalidSkill(let s):
            return "Invalid skill: \(s)"
        }
    }
}
