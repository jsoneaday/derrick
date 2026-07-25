import Foundation

/// Why a `DockerRunRequest` was rejected before process spawn.
/// Step 1 covers host process allowlisting only; docker argv/env checks come later.
public enum DockerRunRequestValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyExecutablePath
    case relativeExecutablePath(String)
    case disallowedExecutable(String)
    case missingArguments
    case missingDockerInvocation

    /// Stable prefix so the app can detect validation failures from `launchError`.
    public static let launchErrorPrefix = "XPC validation:"

    public var description: String {
        switch self {
        case .emptyExecutablePath:
            return "\(Self.launchErrorPrefix) executable path is empty"
        case .relativeExecutablePath(let path):
            return "\(Self.launchErrorPrefix) executable path must be absolute (got \(path))"
        case .disallowedExecutable(let path):
            return "\(Self.launchErrorPrefix) executable is not allowed: \(path)"
        case .missingArguments:
            return "\(Self.launchErrorPrefix) process arguments are empty"
        case .missingDockerInvocation:
            return "\(Self.launchErrorPrefix) first argument must be docker when using /usr/bin/env"
        }
    }

    public var launchErrorMessage: String { description }
}

/// Host-process allowlist for privileged helper launches.
///
/// Intended legitimate form (matches current app client):
/// - `executablePath == "/usr/bin/env"`
/// - `arguments[0] == "docker"`
public enum DockerRunRequestValidator: Sendable {
    public static let allowedEnvExecutablePath = "/usr/bin/env"
    public static let requiredEnvFirstArgument = "docker"

    /// Validates that the request only launches the docker CLI via `/usr/bin/env`.
    public static func validateProcessAllowlist(_ request: DockerRunRequest) -> DockerRunRequestValidationError? {
        let path = request.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return .emptyExecutablePath
        }
        guard path.hasPrefix("/") else {
            return .relativeExecutablePath(path)
        }
        guard path == allowedEnvExecutablePath else {
            return .disallowedExecutable(path)
        }
        guard let first = request.arguments.first else {
            return .missingArguments
        }
        guard first == requiredEnvFirstArgument else {
            return .missingDockerInvocation
        }
        return nil
    }
}
