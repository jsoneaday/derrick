import Foundation

/// Shared, immutable host-side launch constants for the privileged Docker helper path.
///
/// Single source of truth for executable path, docker CLI name, PATH, and resource limits.
/// Used by the app client, MCPServer direct runner, validator, and helper.
public enum DockerHostLaunch: Sendable {
    /// Host binary used to invoke the docker CLI (`env docker …`).
    public static let envExecutablePath = "/usr/bin/env"

    /// First argument to `/usr/bin/env` (looks up docker on PATH).
    public static let dockerCommandName = "docker"

    /// Fixed PATH for locating `docker` (and only trusted system dirs).
    public static let pathEnvironmentValue =
        "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static let minTimeoutSeconds = 1
    /// Allows cold baseline builds that install Playwright Chromium (often >10 minutes).
    public static let maxTimeoutSeconds = 1_200
    /// Max stdin payload for Swift source, artifacts, and envelope input.
    public static let maxStdinBytes = 5 * 1024 * 1024

    /// Docker CLI subcommands the product may invoke.
    public static let allowedDockerSubcommands: Set<String> = [
        "version",
        "pull",
        "build",
        "create",
        "start",
        "exec",
        "rm",
        "inspect",
        "image"
    ]

    /// Second-level tokens for `docker image …`.
    public static let allowedImageSubcommands: Set<String> = [
        "inspect"
    ]

    /// Exact flags that must never appear on the docker CLI.
    public static let forbiddenExactFlags: Set<String> = [
        "--privileged",
        "--pid=host",
        "--network=host",
        "--ipc=host",
        "--userns=host",
        "--cgroupns=host"
    ]

    /// Prefixes for forbidden flags (`--privileged=true`, etc.).
    public static let forbiddenFlagPrefixes: [String] = [
        "--privileged=",
        "--pid=host",
        "--network=host",
        "--ipc=host",
        "--userns=host",
        "--cgroupns=host",
        "--device=",
        "--device-cgroup-rule=",
        "--add-host",
        "--add-host=",
    ]

    /// Full process argv: `["docker"] + dockerArgs`.
    public static func dockerCLIArguments(_ dockerArgs: [String]) -> [String] {
        [dockerCommandName] + dockerArgs
    }

    /// Environment the **client** may attach to a request (informational / local runners).
    /// The privileged helper **ignores** client env and uses `helperProcessEnvironment()` instead.
    public static func clientProcessEnvironment(
        homeDirectory: String = NSHomeDirectory(),
        temporaryDirectory: String = NSTemporaryDirectory()
    ) -> [String: String] {
        [
            "HOME": homeDirectory,
            "PATH": pathEnvironmentValue,
            "TMPDIR": temporaryDirectory
        ]
    }

    /// Environment the **helper** applies to every spawn (not client-controlled).
    public static func helperProcessEnvironment(
        homeDirectory: String = NSHomeDirectory(),
        temporaryDirectory: String = NSTemporaryDirectory()
    ) -> [String: String] {
        [
            "HOME": homeDirectory,
            "PATH": pathEnvironmentValue,
            "TMPDIR": temporaryDirectory,
            "DOCKER_HOST": "unix://\(homeDirectory)/.docker/run/docker.sock"
        ]
    }

    /// Builds a request using centralized executable and docker prefix.
    /// - Parameter dockerArguments: Args **after** `docker` (e.g. `["exec", "-i", …]`).
    public static func makeRequest(
        dockerArguments: [String],
        stdinData: Data = Data(),
        timeoutSeconds: Int,
        environment: [String: String] = clientProcessEnvironment()
    ) -> DockerRunRequest {
        DockerRunRequest(
            executablePath: envExecutablePath,
            arguments: dockerCLIArguments(dockerArguments),
            environment: environment,
            stdinData: stdinData,
            timeoutSeconds: timeoutSeconds
        )
    }

    public static func clampTimeout(_ seconds: Int) -> Int {
        min(max(seconds, minTimeoutSeconds), maxTimeoutSeconds)
    }
}

/// Launch plan after validation; helper must spawn only from this type.
public struct ApprovedDockerLaunch: Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let stdinData: Data
    public let timeoutSeconds: Int

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        stdinData: Data,
        timeoutSeconds: Int
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.stdinData = stdinData
        self.timeoutSeconds = timeoutSeconds
    }
}
