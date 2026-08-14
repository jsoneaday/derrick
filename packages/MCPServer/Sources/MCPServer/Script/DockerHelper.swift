import Foundation
import ServiceContracts
import DockerRunnerXPC

/// Docker image, create/exec argv, and guest helpers for the Bun script runtime.
public enum DockerScriptPreparer {
    public static let parentImage = "oven/bun:1-debian"
    public static let baselineImageVersion = "1"
    public static var defaultImage: String {
        DerrickGuestRuntime.dockerImage
    }

    public static let helpersPath = "/opt/derrick"
    public static let runnerPath = "\(helpersPath)/runner.js"
    public static let derrickModulePath = "\(helpersPath)/derrick.js"
    public static let workspacePath = "/workspace"

    public static let warmContainerGeneration = "1"
    public static var warmContainerPrefix: String { "derrick-runner-bun-\(warmContainerGeneration)" }

    public static let poolSlotCount = 3
    public static let warmStandbySlotIndex = 0

    public static var containerRunMaxTTLSeconds: Int {
        ContainerLifecycleRuntime.containerRunMaxTTLSeconds
    }

    public static func effectiveScriptTimeoutSeconds(requested: Int) -> Int {
        min(max(requested, 1), containerRunMaxTTLSeconds)
    }

    public static func containerLeaseExceededExplanation(maxSeconds: Int = containerRunMaxTTLSeconds) -> String {
        let minutes = maxSeconds / 60
        return """
        Docker container lease expired after \(maxSeconds)s (\(minutes) minutes). Each script_exec run may hold a container for at most \(maxSeconds)s so other agents are not blocked. Shorten the script, lower timeout_seconds, or split the work into smaller runs.
        """
    }

    public static func poolContainerName(slotIndex: Int) -> String {
        "\(warmContainerPrefix)-\(slotIndex)"
    }

    /// Retired pool names the current daemon will never exec into.
    public static let legacyWarmContainerNames: [String] = [
        "derrick-runner-net-px4",
        "derrick-runner-nonet-px4",
        "derrick-runner-net-px5",
        "derrick-runner-nonet-px5",
        "derrick-runner-bun-bun1-0",
        "derrick-runner-bun-bun1-1",
        "derrick-runner-bun-bun1-2",
    ]

    public static let warmContainerMemory = "1g"
    public static let warmContainerCPUs = "2.0"
    public static let warmContainerPIDsLimit = "256"
    public static let warmContainerTmpfsSize = "512m"
    public static let parentImagePullTimeoutSeconds = 600
    public static let baselineImageBuildTimeoutSeconds = 300

    public static let holdBinary = "/bin/sleep"
    public static let holdArg = "infinity"

    public static var guestRunnerJS: String {
        #"""
        const chunks = [];
        for await (const chunk of Bun.stdin.stream()) {
          chunks.push(chunk);
        }
        const raw = Buffer.concat(chunks).toString("utf8");
        let invoke = {};
        try { invoke = raw ? JSON.parse(raw) : {}; } catch (e) {
          console.error("invalid invoke JSON");
          process.exit(1);
        }
        const { pathToFileURL } = await import("url");
        const mod = await import(pathToFileURL("/workspace/script.js").href);
        if (typeof mod.handle !== "function") {
          console.error("script must export function handle");
          process.exit(1);
        }
        const origLog = console.log;
        const origErr = console.error;
        console.log = () => {};
        console.error = (...a) => { origErr(...a); };
        let result;
        try {
          result = await mod.handle(invoke.event ?? invoke);
        } catch (e) {
          origErr(String(e && e.stack ? e.stack : e));
          process.exit(1);
        } finally {
          console.log = origLog;
          console.error = origErr;
        }
        if (!Array.isArray(result)) {
          if (result && typeof result === "object") {
            result = [result];
          } else {
            origErr("handle() must return an envelope object or array");
            process.exit(1);
          }
        }
        process.stdout.write(JSON.stringify(result));
        """#
    }

    public static var guestDerrickJS: String {
        #"""
        function oneRequest({ method, url, authRef, json, headers } = {}) {
          return {
            verb: "http.request",
            request_id: crypto.randomUUID(),
            method: method || "GET",
            url: url || "",
            auth_ref: authRef ?? null,
            json: json ?? null,
            headers: headers ?? {},
          };
        }
        export function netFetch(opts = {}) {
          if (Array.isArray(opts.requests)) {
            return opts.requests.map((item) => oneRequest(item));
          }
          if (Array.isArray(opts)) {
            return opts.map((item) => oneRequest(item));
          }
          return oneRequest(opts);
        }
        """#
    }

    public static var baselineDockerfile: String {
        let runnerB64 = Data(guestRunnerJS.utf8).base64EncodedString()
        let derrickB64 = Data(guestDerrickJS.utf8).base64EncodedString()
        return """
        FROM \(parentImage)
        RUN apt-get update \\
         && apt-get install -y --no-install-recommends ca-certificates \\
         && rm -rf /var/lib/apt/lists/* \\
         && mkdir -p \(helpersPath) \\
         && echo \(runnerB64) | base64 -d > \(runnerPath) \\
         && echo \(derrickB64) | base64 -d > \(derrickModulePath)
        ENV HOME=/tmp/home
        ENV TMPDIR=/tmp
        """
    }

    public static func processEnvironment() -> [String: String] {
        DockerHostLaunch.clientProcessEnvironment()
    }

    public static func dockerBuildBaselineArguments() -> [String] {
        ["build", "-t", defaultImage, "-"]
    }

    public static func dockerImageInspectArguments(_ image: String) -> [String] {
        ["image", "inspect", image]
    }

    public static func dockerPullArguments(_ image: String) -> [String] {
        ["pull", image]
    }

    public static func dockerRmForceArguments(container: String) -> [String] {
        ["rm", "-f", container]
    }

    public static func dockerStartArguments(containerName: String) -> [String] {
        ["start", containerName]
    }

    public static func dockerInspectContainerRunningArguments(containerName: String) -> [String] {
        ["inspect", "-f", "{{.State.Running}}", containerName]
    }

    public static func dockerCreateWarmContainerArguments(containerName: String) -> [String] {
        [
            "create",
            "--network", "bridge",
            "--name", containerName,
            "--init",
            "--tmpfs", "/tmp:rw,nosuid,size=\(warmContainerTmpfsSize)",
            "--tmpfs", "/var/tmp:rw,nosuid,size=128m",
            "--tmpfs", "\(workspacePath):rw,nosuid,size=\(warmContainerTmpfsSize)",
            "--pids-limit", warmContainerPIDsLimit,
            "--cpus", warmContainerCPUs,
            "--memory", warmContainerMemory,
            "--security-opt", "no-new-privileges",
            "--cap-drop", "ALL",
            "-e", "HOME=/tmp/home",
            "-e", "TMPDIR=/tmp",
            "--entrypoint", holdBinary,
            defaultImage,
            holdArg,
        ]
    }

    /// Compatibility alias used by older tests (always the Bun warm create).
    public static func dockerCreateWarmContainerArguments(allowNetwork: Bool) -> [String] {
        _ = allowNetwork
        return dockerCreateWarmContainerArguments(containerName: poolContainerName(slotIndex: 0))
    }

    public static func dockerNetworkDisconnectArguments(containerName: String) -> [String] {
        ["network", "disconnect", "bridge", containerName]
    }

    public static func dockerExecBunEArguments(containerName: String) -> [String] {
        ["exec", "-i", containerName, "bun", "-e"]
    }

    public static func dockerExecRunnerArguments(containerName: String) -> [String] {
        ["exec", "-i", containerName, "bun", runnerPath]
    }

    public static func dockerExecInstallArguments(containerName: String) -> [String] {
        ["exec", "-w", workspacePath, containerName, "bun", "install"]
    }

    public static func dockerExecWriteScriptArguments(containerName: String) -> [String] {
        // Reads script.js from stdin.
        ["exec", "-i", containerName, "bun", "-e", "await Bun.write('/workspace/script.js', await Bun.stdin.text())"]
    }

    public static func dockerExecWriteRunnerArguments(containerName: String) -> [String] {
        ["exec", "-i", containerName, "bun", "-e", "await Bun.write('\(runnerPath)', await Bun.stdin.text())"]
    }

    public static func dockerExecWriteDerrickModuleArguments(containerName: String) -> [String] {
        ["exec", "-i", containerName, "bun", "-e", "await Bun.write('\(derrickModulePath)', await Bun.stdin.text())"]
    }

    public static func dockerExecWritePackageJSONArguments(containerName: String) -> [String] {
        ["exec", "-i", containerName, "bun", "-e", "await Bun.write('/workspace/package.json', await Bun.stdin.text())"]
    }

    public static func makePackageJSON(dependencies: [String: String]) -> String {
        let deps = dependencies.mapValues { $0 }
        let obj: [String: Any] = [
            "name": "derrick-script",
            "private": true,
            "type": "module",
            "dependencies": deps,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public static func dockerExecArguments(containerName: String) -> [String] {
        dockerExecRunnerArguments(containerName: containerName)
    }

    public static func dockerUnavailableMessage(stderr: String, exitCode: Int32) -> String? {
        let lowered = stderr.lowercased()
        if exitCode == 127 {
            return "Docker Desktop is required for script_exec. Install Docker Desktop and ensure `docker` is available in PATH."
        }
        if lowered.contains("connect to the docker daemon") ||
            lowered.contains("cannot connect to the docker daemon") ||
            lowered.contains("error during connect") ||
            lowered.contains("docker.sock") ||
            lowered.contains("/var/run/docker.sock") {
            return "Docker Desktop appears unavailable. Start Docker Desktop and retry script_exec."
        }
        return nil
    }
}

/// Test / non-sandboxed stub. Production uses helper XPC + `ScriptExecutionRuntime`.
public final class DockerScriptRunner: ScriptRunner, @unchecked Sendable {
    public init(dockerImage: String = DockerScriptPreparer.defaultImage) {
        _ = dockerImage
    }

    public func run(
        script: String,
        timeoutSeconds: Int,
        allowNetwork: Bool,
        packages: [String],
        allowDependencyInstall: Bool
    ) async throws -> ScriptExecutionResult {
        _ = script
        _ = timeoutSeconds
        _ = allowNetwork
        _ = packages
        _ = allowDependencyInstall
        throw NSError(
            domain: "MCPServer",
            code: 501,
            userInfo: [NSLocalizedDescriptionKey: "Direct DockerScriptRunner is retired; use script_exec via helper XPC."]
        )
    }
}
