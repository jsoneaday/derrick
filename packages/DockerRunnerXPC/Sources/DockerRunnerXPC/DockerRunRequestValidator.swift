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

/// Validates and approves host process launches for the privileged helper.
public enum DockerRunRequestValidator: Sendable {
    /// Process allowlist only (legacy step-1 entry point).
    public static func validateProcessAllowlist(_ request: DockerRunRequest) -> DockerRunRequestValidationError? {
        validateExecutableAndDockerPrefix(request)
    }

    /// Full validation: process form, docker argv policy, timeout, stdin size.
    public static func validate(_ request: DockerRunRequest) -> DockerRunRequestValidationError? {
        if let error = validateExecutableAndDockerPrefix(request) {
            return error
        }
        if let error = validateDockerArguments(Array(request.arguments.dropFirst())) {
            return error
        }
        if let error = validateLimits(request) {
            return error
        }
        return nil
    }

    /// Validate and produce a helper-ready launch (helper-owned environment, clamped timeout).
    public static func approve(
        _ request: DockerRunRequest,
        homeDirectory: String = NSHomeDirectory(),
        temporaryDirectory: String = NSTemporaryDirectory()
    ) -> Result<ApprovedDockerLaunch, DockerRunRequestValidationError> {
        if let error = validate(request) {
            return .failure(error)
        }
        let launch = ApprovedDockerLaunch(
            executablePath: DockerHostLaunch.envExecutablePath,
            arguments: request.arguments,
            environment: DockerHostLaunch.helperProcessEnvironment(
                homeDirectory: homeDirectory,
                temporaryDirectory: temporaryDirectory
            ),
            stdinData: request.stdinData,
            timeoutSeconds: DockerHostLaunch.clampTimeout(request.timeoutSeconds)
        )
        return .success(launch)
    }

    // MARK: - Process form

    private static func validateExecutableAndDockerPrefix(
        _ request: DockerRunRequest
    ) -> DockerRunRequestValidationError? {
        let path = request.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return .emptyExecutablePath
        }
        guard path.hasPrefix("/") else {
            return .relativeExecutablePath(path)
        }
        guard path == DockerHostLaunch.envExecutablePath else {
            return .disallowedExecutable(path)
        }
        guard let first = request.arguments.first else {
            return .missingArguments
        }
        guard first == DockerHostLaunch.dockerCommandName else {
            return .missingDockerInvocation
        }
        return nil
    }

    // MARK: - Limits

    private static func validateLimits(_ request: DockerRunRequest) -> DockerRunRequestValidationError? {
        let timeout = request.timeoutSeconds
        if timeout < DockerHostLaunch.minTimeoutSeconds || timeout > DockerHostLaunch.maxTimeoutSeconds {
            return .timeoutOutOfRange(timeout)
        }
        let stdinCount = request.stdinData.count
        if stdinCount > DockerHostLaunch.maxStdinBytes {
            return .stdinTooLarge(stdinCount)
        }
        return nil
    }

    // MARK: - Docker argv

    /// - Parameter dockerArgs: Arguments **after** the `docker` token.
    private static func validateDockerArguments(_ dockerArgs: [String]) -> DockerRunRequestValidationError? {
        guard let subcommand = dockerArgs.first, !subcommand.isEmpty else {
            return .disallowedDockerSubcommand("<missing>")
        }
        guard DockerHostLaunch.allowedDockerSubcommands.contains(subcommand) else {
            return .disallowedDockerSubcommand(subcommand)
        }

        if subcommand == "image" {
            guard let second = dockerArgs.dropFirst().first,
                  DockerHostLaunch.allowedImageSubcommands.contains(second) else {
                return .disallowedDockerSubcommand("image \(dockerArgs.dropFirst().first ?? "<missing>")")
            }
        }
        if subcommand == "exec",
           let error = validateExecArguments(dockerArgs) {
            return error
        }
        var index = 0
        while index < dockerArgs.count {
            let arg = dockerArgs[index]
            if let error = validateFlagToken(arg) {
                return error
            }
            // Split form: `--network host`, `--pid host`, etc.
            if ["--network", "--pid", "--ipc", "--userns", "--cgroupns"].contains(arg),
               index + 1 < dockerArgs.count,
               dockerArgs[index + 1] == "host" {
                return .disallowedDockerFlag("\(arg)=host")
            }

            if arg == "-v" || arg == "--volume" {
                let value = index + 1 < dockerArgs.count ? dockerArgs[index + 1] : "<missing>"
                return .disallowedVolumeMount(value)
            } else if arg.hasPrefix("-v=") || arg.hasPrefix("--volume=") {
                return .disallowedVolumeMount(String(arg.split(separator: "=", maxSplits: 1).last ?? ""))
            } else if arg == "--mount" || arg.hasPrefix("--mount=") {
                let value: String
                if arg.hasPrefix("--mount=") {
                    value = String(arg.dropFirst("--mount=".count))
                } else if index + 1 < dockerArgs.count {
                    value = dockerArgs[index + 1]
                    index += 1
                } else {
                    return .disallowedDockerFlag("--mount")
                }
                let lowered = value.lowercased()
                if lowered.contains("type=bind") || lowered.contains("bind,") {
                    return .disallowedVolumeMount(value)
                }
            } else if arg == "--device" || arg.hasPrefix("--device=") {
                return .disallowedDockerFlag(arg)
            }
            index += 1
        }
        return nil
    }

    private static func validateFlagToken(_ arg: String) -> DockerRunRequestValidationError? {
        if DockerHostLaunch.forbiddenExactFlags.contains(arg) {
            return .disallowedDockerFlag(arg)
        }
        for prefix in DockerHostLaunch.forbiddenFlagPrefixes {
            if arg == prefix || arg.hasPrefix(prefix) {
                return .disallowedDockerFlag(arg)
            }
        }
        return nil
    }

    private static func validateExecArguments(
        _ dockerArgs: [String]
    ) -> DockerRunRequestValidationError? {
        var args = Array(dockerArgs.dropFirst())
        while args.first == "-i" || args.first == "--interactive" {
            args.removeFirst()
        }
        guard args.count >= 2 else {
            return .disallowedDockerFlag("exec")
        }
        args.removeFirst() // container name
        guard let command = args.first else {
            return .disallowedDockerFlag("exec")
        }

        switch command {
        case "sh":
            guard args.count == 3,
                  args[1] == "-c",
                  (args[2] == "cat > /tmp/plugin.swift"
                    || args[2] == "cat > /tmp/plugin")
            else {
                return .disallowedDockerFlag("exec \(command)")
            }
        case "swift":
            guard args.count == 2, args[1] == "/tmp/plugin.swift" else {
                return .disallowedDockerFlag("exec \(command)")
            }
        case "swiftc":
            guard args == ["swiftc", "-O", "/tmp/plugin.swift", "-o", "/tmp/plugin"] else {
                return .disallowedDockerFlag("exec \(command)")
            }
        case "base64":
            guard args == ["base64", "-w", "0", "/tmp/plugin"] else {
                return .disallowedDockerFlag("exec \(command)")
            }
        case "chmod":
            guard args == ["chmod", "700", "/tmp/plugin"] else {
                return .disallowedDockerFlag("exec \(command)")
            }
        case "/tmp/plugin":
            guard args == ["/tmp/plugin"] else {
                return .disallowedDockerFlag("exec \(command)")
            }
        default:
            return .disallowedDockerFlag("exec \(command)")
        }
        return nil
    }

}
