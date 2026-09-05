import Foundation

/// Why a `DockerRunRequest` was rejected before process spawn.
public enum DockerRunRequestValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyExecutablePath
    case relativeExecutablePath(String)
    case disallowedExecutable(String)
    case missingArguments
    case missingDockerInvocation
    case disallowedDockerSubcommand(String)
    case disallowedDockerFlag(String)
    case disallowedVolumeMount(String)
    case timeoutOutOfRange(Int)
    case stdinTooLarge(Int)

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
            return "\(Self.launchErrorPrefix) first argument must be \(DockerHostLaunch.dockerCommandName) when using \(DockerHostLaunch.envExecutablePath)"
        case .disallowedDockerSubcommand(let name):
            return "\(Self.launchErrorPrefix) docker subcommand is not allowed: \(name)"
        case .disallowedDockerFlag(let flag):
            return "\(Self.launchErrorPrefix) docker flag is not allowed: \(flag)"
        case .disallowedVolumeMount(let value):
            return "\(Self.launchErrorPrefix) host bind mount is not allowed: \(value)"
        case .timeoutOutOfRange(let value):
            return "\(Self.launchErrorPrefix) timeoutSeconds out of range: \(value) (allowed \(DockerHostLaunch.minTimeoutSeconds)…\(DockerHostLaunch.maxTimeoutSeconds))"
        case .stdinTooLarge(let bytes):
            return "\(Self.launchErrorPrefix) stdin exceeds max size (\(bytes) > \(DockerHostLaunch.maxStdinBytes) bytes)"
        }
    }

    public var launchErrorMessage: String { description }
}
