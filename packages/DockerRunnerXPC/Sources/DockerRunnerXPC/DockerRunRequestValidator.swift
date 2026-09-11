import Foundation
import Structure

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

        if subcommand == "image",
           let error = validateImageArguments(dockerArgs) {
            return error
        }
        if subcommand == "exec",
           let error = validateExecArguments(dockerArgs) {
            return error
        }
        if subcommand == "build",
           let error = validateBuildArguments(dockerArgs) {
            return error
        }
        if subcommand == "ps",
           let error = validatePsArguments(dockerArgs) {
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
                if !FileJobBindMountPolicy.isAllowedVolumeSpec(value) {
                    return .disallowedVolumeMount(value)
                }
                index += 1
            } else if arg.hasPrefix("-v=") || arg.hasPrefix("--volume=") {
                let value = String(arg.split(separator: "=", maxSplits: 1).last ?? "")
                if !FileJobBindMountPolicy.isAllowedVolumeSpec(value) {
                    return .disallowedVolumeMount(value)
                }
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
        if subcommand == "create",
           !DerrickDockerRuntimeIdentity.createHasRuntimeLabel(dockerArgs) {
            return .disallowedDockerFlag("create missing runtime label")
        }
        return nil
    }

    /// `docker ps -aq --filter label=app.derrick=runtime` (or an allowed name prefix).
    private static func validatePsArguments(
        _ dockerArgs: [String]
    ) -> DockerRunRequestValidationError? {
        guard dockerArgs.count == 4,
              dockerArgs[1] == "-aq",
              dockerArgs[2] == "--filter",
              DerrickDockerRuntimeIdentity.isAllowedPsFilter(dockerArgs[3])
        else {
            return .disallowedDockerFlag("ps")
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
                  args[2] == "cat > /tmp/guest && chmod +x /tmp/guest"
                      || args[2] == DockerWorkerRuntime.guestWriteSourceShell
                      || args[2] == DockerWorkerRuntime.guestCompileShell
                      || args[2] == DockerWorkerRuntime.guestReadBinaryShell
            else {
                return .disallowedDockerFlag("exec \(command)")
            }
        case DockerWorkerRuntime.crawlerBinary,
             DockerWorkerRuntime.extractorBinary,
             DockerWorkerRuntime.newsReaderBinary,
             DockerWorkerRuntime.guestBinaryPath:
            guard args == [command] else {
                return .disallowedDockerFlag("exec \(command)")
            }
        default:
            return .disallowedDockerFlag("exec \(command)")
        }
        return nil
    }

    /// `docker build -f <dockerfile> -t <tag> <context>` for trusted product images only.
    private static func validateBuildArguments(
        _ dockerArgs: [String]
    ) -> DockerRunRequestValidationError? {
        var args = Array(dockerArgs.dropFirst())
        guard args.count >= 5,
              args[0] == "-f",
              args[2] == "-t" else {
            return .disallowedDockerFlag("build arguments")
        }
        let dockerfile = args[1]
        let tag = args[3]
        let context = args[4]
        guard args.count == 5 else {
            return .disallowedDockerFlag("build extra arguments")
        }
        if DockerProductImagePolicy.isAllowedWorkerBuild(
            dockerfilePath: dockerfile,
            imageTag: tag,
            contextPath: context
        ) {
            return nil
        }
        if DockerProductImagePolicy.isAllowedWebCrawlerBuild(
            dockerfilePath: dockerfile,
            imageTag: tag,
            contextPath: context
        ) {
            return nil
        }
        return .disallowedDockerFlag("build product image")
    }

    private static func validateImageArguments(
        _ dockerArgs: [String]
    ) -> DockerRunRequestValidationError? {
        let args = Array(dockerArgs.dropFirst())
        guard let second = args.first,
              DockerHostLaunch.allowedImageSubcommands.contains(second) else {
            return .disallowedDockerSubcommand("image \(args.first ?? "<missing>")")
        }
        guard second == "inspect" else { return nil }
        if args.count == 2 {
            return nil
        }
        guard args.count == 4,
              args[1] == "--format",
              args[2] == "{{.Id}}" else {
            return .disallowedDockerFlag("image inspect")
        }
        let tag = args[3]
        guard tag == DockerWorkerRuntime.image
            || tag == DockerProductImagePolicy.webCrawlerImage
            || tag == DerrickGuestRuntime.guestDockerImage else {
            return .disallowedDockerFlag("image inspect tag")
        }
        return nil
    }

}
