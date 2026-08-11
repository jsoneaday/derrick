//
//  DockerHelper.swift
//  MCPServer
//
//  Created by David Choi on 7/24/26.
//

import Foundation
import ServiceContracts
import DockerRunnerXPC

/// Utilities for preparing docker run arguments and Python execution scripts.
/// Shared by:
/// - UI prewarm / exec via `XPCDockerRunner` (helper Application XPC)
/// - MCPService exec via `MCPServiceDockerHelperRunner` (helper peer XPC)
/// - package tests / non-sandboxed `DockerPythonScriptRunner` (direct CLI only)
public enum DockerScriptPreparer {
    /// Parent image used when building the local baseline image.
    public static let parentImage = "ghcr.io/astral-sh/uv:debian"

    /// Bump when baseline package set or Dockerfile changes so prewarm rebuilds.
    public static let baselineImageVersion = "6"

    /// Local image with baseline packages baked in (`docker build` on prewarm if missing).
    public static var defaultImage: String {
        "derrick-python:baseline-\(baselineImageVersion)"
    }

    /// Virtualenv inside the baseline image (avoids Debian "externally managed" system Python).
    public static let baselineVenvPath = "/opt/derrick-venv"
    public static var baselinePythonPath: String {
        "\(baselineVenvPath)/bin/python"
    }

    /// Playwright browser binaries path (baked at image build; not under the read-only root only).
    public static let playwrightBrowsersPath = "/opt/pw-browsers"

    /// Crawlee default `./storage` is on the read-only root — force writable tmpfs.
    public static let crawleeStorageDir = "/tmp/crawlee-storage"

    /// Net-container hold process: installs OUTPUT iptables policy then sleeps.
    public static let forcedEgressHoldPath = "/usr/local/bin/derrick-net-hold"

    public static let pipCacheVolume = "derrick-pip-cache"
    public static let packagesVolume = "derrick-python-packages"
    /// Bump when create-args change (e.g. forced egress / limits / crawlee storage) so warm containers recreate.
    public static let warmContainerGeneration = "px5"
    public static var warmContainerNetwork: String { "derrick-runner-net-\(warmContainerGeneration)" }
    public static var warmContainerNoNetwork: String { "derrick-runner-nonet-\(warmContainerGeneration)" }

    /// Networked execution pool: two slots max, one warm standby (slot 0).
    public static let networkPoolSlotCount = 2
    public static let networkPoolStandbySlotIndex = 0
    public static let networkPoolWarmStandbyCount = 1

    /// Offline execution pool: one slot max, queued, no warm standby.
    public static let offlinePoolSlotCount = 1

    /// Hard cap on how long one container lease may run (seconds). Queue wait is excluded.
    public static var containerRunMaxTTLSeconds: Int {
        ContainerLifecycleRuntime.containerRunMaxTTLSeconds
    }

    public static func effectiveScriptTimeoutSeconds(requested: Int) -> Int {
        min(max(requested, 1), containerRunMaxTTLSeconds)
    }

    public static func containerLeaseExceededExplanation(maxSeconds: Int = containerRunMaxTTLSeconds) -> String {
        let minutes = maxSeconds / 60
        return """
        Docker container lease expired after \(maxSeconds)s (\(minutes) minutes). Each python_script_exec run may hold a container for at most \(maxSeconds)s so other agents are not blocked. Shorten the script, lower timeout_seconds, or split the work into smaller runs.
        """
    }

    public static func networkPoolContainerName(slotIndex: Int) -> String {
        "\(warmContainerNetwork)-\(slotIndex)"
    }

    public static func offlinePoolContainerName(slotIndex: Int) -> String {
        "\(warmContainerNoNetwork)-\(slotIndex)"
    }

    public static func dockerCreateOfflineContainerArguments(containerName: String) -> [String] {
        dockerCreateNetworkedWarmContainerArguments(containerName: containerName, allowNetwork: false)
    }

    /// Prior single-container names removed during pool prewarm.
    public static let legacyWarmContainerNames: [String] = [
        "derrick-runner-net-px4",
        "derrick-runner-nonet-px4"
    ]

    /// Pip install specs baked into the image (extras syntax allowed).
    public static let baselinePipSpecs: [String] = [
        "requests",
        "chardet",
        "lxml",
        "crawlee[playwright,beautifulsoup]"
    ]

    /// Package names treated as already available (no `/packages` install).
    /// `beautifulsoup4` / `playwright` arrive via the crawlee extras; listed so agents need not reinstall.
    public static let baselinePackages: Set<String> = [
        "requests",
        "chardet",
        "lxml",
        "beautifulsoup4",
        "crawlee",
        "crawlee[playwright]",
        "crawlee[beautifulsoup]",
        "crawlee[playwright,beautifulsoup]",
        "crawlee[all]",
        "playwright"
    ]

    /// Warm-container resource limits sized for Chromium via Playwright/Crawlee.
    public static let warmContainerMemory = "2g"
    public static let warmContainerCPUs = "2.0"
    public static let warmContainerPIDsLimit = "256"
    public static let warmContainerShmSize = "1g"
    public static let warmContainerNofile = "4096:4096"
    public static let warmContainerTmpfsSize = "512m"

    /// Cold `docker pull` of the uv/debian parent on a wiped Docker store.
    public static let parentImagePullTimeoutSeconds = 600
    /// Cold baseline build installs crawlee + Playwright Chromium (often several minutes).
    public static let baselineImageBuildTimeoutSeconds = 900

    /// Hold script for networked containers (written into the image via base64).
    /// No leading indentation — shebang must be at column 0.
    public static let forcedEgressHoldScript: String = #"""
#!/bin/sh
set +e
PROXY_PORT="${DERRICK_PROXY_PORT:-18080}"
HOST_IP=""
if command -v getent >/dev/null 2>&1; then
  HOST_IP=$(getent hosts host.docker.internal 2>/dev/null | head -n1 | cut -d' ' -f1)
fi
if [ -z "$HOST_IP" ]; then
  HOST_IP=$(python3 -c 'import socket; print(socket.gethostbyname("host.docker.internal"))' 2>/dev/null)
fi
iptables -F OUTPUT 2>/dev/null
iptables -P OUTPUT DROP
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
if [ $? -ne 0 ]; then
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
fi
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -d 127.0.0.11 -j ACCEPT
if [ -n "$HOST_IP" ]; then
  iptables -A OUTPUT -p tcp -d "$HOST_IP" --dport "$PROXY_PORT" -j ACCEPT
  echo "[derrick-net-hold] forced egress: only tcp/$PROXY_PORT -> $HOST_IP" >&2
else
  echo "[derrick-net-hold] WARNING: host.docker.internal unresolved" >&2
fi
ip6tables -F OUTPUT 2>/dev/null
ip6tables -P OUTPUT DROP 2>/dev/null
exec /bin/sleep infinity
"""#

    public static var baselineDockerfile: String {
        let packages = baselinePipSpecs
            .map { spec in
                let escaped = spec.replacingOccurrences(of: "'", with: "'\\''")
                return "'\(escaped)'"
            }
            .joined(separator: " ")
        let holdB64 = Data(forcedEgressHoldScript.utf8).base64EncodedString()
        // Debian/uv images mark system Python as externally managed (PEP 668).
        // Net hold script forces OUTPUT via host proxy only (item 4).
        // Playwright Chromium + OS deps are baked once at image build (first prewarm).
        return """
        FROM \(parentImage)
        RUN apt-get update \\
         && apt-get install -y --no-install-recommends iptables iproute2 ca-certificates \\
         && uv venv \(baselineVenvPath) \\
         && uv pip install --python \(baselinePythonPath) --no-cache \(packages) \\
         && PLAYWRIGHT_BROWSERS_PATH=\(playwrightBrowsersPath) \(baselineVenvPath)/bin/playwright install --with-deps chromium \\
         && rm -rf /var/lib/apt/lists/* \\
         && echo \(holdB64) | base64 -d > \(forcedEgressHoldPath) \\
         && chmod 755 \(forcedEgressHoldPath)
        ENV VIRTUAL_ENV=\(baselineVenvPath)
        ENV PATH="\(baselineVenvPath)/bin:$$PATH"
        ENV PLAYWRIGHT_BROWSERS_PATH=\(playwrightBrowsersPath)
        ENV DERRICK_PROXY_PORT=18080
        """
    }

    public static func normalizePackages(_ packages: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for package in packages {
            let normalized = package.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            output.append(normalized)
        }
        return output
    }

    /// True when the package is already in the baseline image (including crawlee extras).
    public static func isBaselinePackageName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if baselinePackages.contains(normalized) { return true }
        if normalized.hasPrefix("crawlee[") && normalized.hasSuffix("]") { return true }
        return false
    }

    /// Packages that are not baked into the baseline image (installed into the packages volume).
    public static func extraPackages(from requested: [String]) -> [String] {
        normalizePackages(requested).filter { !isBaselinePackageName($0) }
    }

    public static func warmContainerName(allowNetwork: Bool) -> String {
        allowNetwork ? warmContainerNetwork : warmContainerNoNetwork
    }

    /// Minimal environment for docker CLI to locate daemon and config.
    /// Delegates to `DockerHostLaunch` so PATH and layout stay centralized.
    public static func processEnvironment() -> [String: String] {
        DockerHostLaunch.clientProcessEnvironment()
    }

    /// Builds the Python wrapper script that optionally installs *extra* packages and runs user code.
    /// Baseline packages are expected to already be present in the image.
    public static func makeExecutionScript(
        script: String,
        installPackages: [String],
        allowDependencyInstall: Bool,
        nonBaselinePackages: [String]
    ) -> String {
        let encodedScript = Data(script.utf8).base64EncodedString()
        let packagesData = (try? JSONSerialization.data(withJSONObject: installPackages, options: [.sortedKeys])) ?? Data("[]".utf8)
        let packagesJSON = String(decoding: packagesData, as: UTF8.self)
        let nonBaselineData = (try? JSONSerialization.data(withJSONObject: nonBaselinePackages, options: [.sortedKeys])) ?? Data("[]".utf8)
        let nonBaselineJSON = String(decoding: nonBaselineData, as: UTF8.self)
        let installEnabled = allowDependencyInstall ? "True" : "False"
        return """
        import ast
        import base64
        import importlib
        import json
        import os
        import pathlib
        import shutil
        import subprocess
        import sys

        install_packages = json.loads('''\(packagesJSON)''')
        non_baseline_packages = json.loads('''\(nonBaselineJSON)''')
        allow_dependency_install = \(installEnabled)

        def _wipe_ephemeral_dir(path: str) -> None:
            root = pathlib.Path(path)
            if not root.is_dir():
                return
            for child in list(root.iterdir()):
                try:
                    if child.is_symlink() or child.is_file():
                        child.unlink(missing_ok=True)
                    elif child.is_dir():
                        shutil.rmtree(child, ignore_errors=True)
                except Exception as error:
                    print(f"[python_script_exec] failed to clean {child}: {error}", file=sys.stderr)

        # Per-run isolation: warm container is reused, but temp dirs must not leak across scripts.
        _wipe_ephemeral_dir("/tmp")
        _wipe_ephemeral_dir("/var/tmp")
        print("[python_script_exec] wiped /tmp and /var/tmp")

        if os.path.isdir("/packages"):
            sys.path.insert(0, "/packages")

        script_source = base64.b64decode("\(encodedScript)").decode("utf-8")
        try:
            ast.parse(script_source)
        except SyntaxError as e:
            print(f"[python_script_exec] Syntax error: {e}", file=sys.stderr)
            sys.exit(1)

        if non_baseline_packages and not allow_dependency_install:
            raise RuntimeError("Requested non-baseline python_packages require allow_dependency_install=true.")
        if install_packages:
            print(f"[python_script_exec] installing packages: {', '.join(install_packages)}")
            # Install extras into the shared /packages volume (image root is read-only).
            # /packages is for dependency trees only — not general script output storage.
            use_uv = False
            try:
                subprocess.run(["uv", "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
                use_uv = True
            except Exception:
                pass

            if use_uv:
                subprocess.run(
                    ["uv", "pip", "install", "--quiet", "--target", "/packages", *install_packages],
                    check=True
                )
            else:
                subprocess.run(
                    [sys.executable, "-m", "pip", "install", "--disable-pip-version-check",
                     "--quiet", "--target", "/packages", *install_packages],
                    check=True
                )
            if "/packages" not in sys.path:
                sys.path.insert(0, "/packages")
            print(f"[python_script_exec] installed packages to /packages: {', '.join(install_packages)}")

        baseline_imports = {
            "requests": "requests",
            "beautifulsoup4": "bs4",
            "chardet": "chardet",
            "lxml": "lxml",
            "crawlee": "crawlee",
            "playwright": "playwright",
        }
        for package_name, module_name in baseline_imports.items():
            try:
                importlib.import_module(module_name)
                print(f"[python_script_exec] verified baseline package: {package_name} -> {module_name}")
            except Exception as error:
                print(
                    f"[python_script_exec] baseline package verification failed: {package_name} -> {module_name}: {error}",
                    file=sys.stderr,
                )
                raise RuntimeError(
                    f"Baseline package verification failed for {package_name} ({module_name})."
                ) from error

        globals_dict = {"__name__": "__main__"}
        exec(compile(script_source, "<python_script_exec>", "exec"), globals_dict, globals_dict)
        """
    }

    /// Lightweight smoke script used during prewarm (no package install).
    public static func makeBaselineSmokeScript() -> String {
        makeExecutionScript(
            script: "print('baseline package smoke complete')",
            installPackages: [],
            allowDependencyInstall: false,
            nonBaselinePackages: []
        )
    }

    public static func dockerBuildBaselineArguments() -> [String] {
        ["build", "-t", defaultImage, "-"]
    }

    public static func dockerVolumeCreateArguments(_ name: String) -> [String] {
        ["volume", "create", name]
    }

    public static func dockerVolumeInspectArguments(_ name: String) -> [String] {
        ["volume", "inspect", name]
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

    public static func dockerInspectContainerImageArguments(allowNetwork: Bool) -> [String] {
        ["inspect", "-f", "{{.Config.Image}}", warmContainerName(allowNetwork: allowNetwork)]
    }

    public static func dockerInspectContainerRunningArguments(allowNetwork: Bool) -> [String] {
        ["inspect", "-f", "{{.State.Running}}", warmContainerName(allowNetwork: allowNetwork)]
    }

    /// Offline hold process. Absolute path required (uv image has no `sleep` on PATH).
    public static let offlineHoldBinary = "/bin/sleep"
    public static let offlineHoldArg = "infinity"

    public static func warmContainerHoldPath(allowNetwork: Bool) -> String {
        allowNetwork ? forcedEgressHoldPath : offlineHoldBinary
    }

    /// Create a long-lived warm container. Does not start it.
    ///
    /// Networked containers: NET_ADMIN + `derrick-net-hold` installs OUTPUT DROP except
    /// host proxy port (forced egress). Offline containers: network none + sleep.
    ///
    /// Image reference is always last (aside from optional offline hold args). Never insert
    /// flags after the image — Docker reports "invalid reference format" if env leaks into
    /// the image position.
    public static func dockerCreateNetworkPoolContainerArguments(containerName: String) -> [String] {
        dockerCreateNetworkedWarmContainerArguments(containerName: containerName)
    }

    public static func dockerCreateWarmContainerArguments(allowNetwork: Bool) -> [String] {
        dockerCreateNetworkedWarmContainerArguments(
            containerName: warmContainerName(allowNetwork: allowNetwork),
            allowNetwork: allowNetwork
        )
    }

    private static func dockerCreateNetworkedWarmContainerArguments(
        containerName: String,
        allowNetwork: Bool = true
    ) -> [String] {
        if allowNetwork {
            var options: [String] = [
                "create",
                "--network", "bridge",
                "--name", containerName,
                "--init",
                "--read-only",
                "--tmpfs", "/tmp:rw,nosuid,size=\(warmContainerTmpfsSize)",
                "--tmpfs", "/var/tmp:rw,nosuid,size=128m",
                "--tmpfs", "/run:rw,nosuid,size=32m",
                "--shm-size", warmContainerShmSize,
                "--pids-limit", warmContainerPIDsLimit,
                "--cpus", warmContainerCPUs,
                "--memory", warmContainerMemory,
                "--security-opt", "no-new-privileges",
                "--cap-drop", "ALL",
                "--cap-add", "NET_ADMIN",
                "--ulimit", "nofile=\(warmContainerNofile)",
                "-v", "\(pipCacheVolume):/root/.cache",
                "-v", "\(packagesVolume):/packages",
                "-e", "DERRICK_PROXY_PORT=18080",
                "-e", "PLAYWRIGHT_BROWSERS_PATH=\(playwrightBrowsersPath)",
                "-e", "CRAWLEE_STORAGE_DIR=\(crawleeStorageDir)",
                "-e", "CRAWLEE_PURGE_ON_START=1",
                "-e", "CRAWLEE_DISABLE_BROWSER_SANDBOX=1",
                "-e", "HOME=/tmp/home",
                "-e", "XDG_CACHE_HOME=/tmp/cache",
                "-e", "TMPDIR=/tmp",
                "--add-host", "host.docker.internal:host-gateway",
                "--entrypoint", forcedEgressHoldPath
            ]
            for (key, value) in containerProxyEnvironment.sorted(by: { $0.key < $1.key }) {
                // Skip empty values; `-e NO_PROXY=` can confuse some CLI parsers.
                guard !value.isEmpty else { continue }
                options.append(contentsOf: ["-e", "\(key)=\(value)"])
            }
            options.append(defaultImage)
            return options
        }

        return [
            "create",
            "--network", "none",
            "--name", containerName,
            "--init",
            "--read-only",
            "--tmpfs", "/tmp:rw,nosuid,size=\(warmContainerTmpfsSize)",
            "--tmpfs", "/var/tmp:rw,nosuid,size=128m",
            "--shm-size", warmContainerShmSize,
            "--pids-limit", warmContainerPIDsLimit,
            "--cpus", warmContainerCPUs,
            "--memory", warmContainerMemory,
            "--security-opt", "no-new-privileges",
            "--cap-drop", "ALL",
            "--ulimit", "nofile=\(warmContainerNofile)",
            "-v", "\(pipCacheVolume):/root/.cache",
            "-v", "\(packagesVolume):/packages",
            "-e", "PLAYWRIGHT_BROWSERS_PATH=\(playwrightBrowsersPath)",
            "-e", "CRAWLEE_STORAGE_DIR=\(crawleeStorageDir)",
            "-e", "CRAWLEE_PURGE_ON_START=1",
            "-e", "CRAWLEE_DISABLE_BROWSER_SANDBOX=1",
            "-e", "HOME=/tmp/home",
            "-e", "XDG_CACHE_HOME=/tmp/cache",
            "-e", "TMPDIR=/tmp",
            "--entrypoint", offlineHoldBinary,
            defaultImage,
            offlineHoldArg
        ]
    }

    /// Proxy env for networked containers. Kept as constants so policy is not model-supplied.
    /// Must stay aligned with `EgressProxyConfiguration` in the EgressProxy package.
    public static let containerProxyEnvironment: [String: String] = [
        "HTTP_PROXY": "http://host.docker.internal:18080",
        "HTTPS_PROXY": "http://host.docker.internal:18080",
        "http_proxy": "http://host.docker.internal:18080",
        "https_proxy": "http://host.docker.internal:18080",
        "ALL_PROXY": "http://host.docker.internal:18080",
        "all_proxy": "http://host.docker.internal:18080",
        "NO_PROXY": "",
        "no_proxy": ""
    ]

    public static func dockerInspectContainerPathArguments(allowNetwork: Bool) -> [String] {
        ["inspect", "-f", "{{.Path}}", warmContainerName(allowNetwork: allowNetwork)]
    }

    public static func dockerStartArguments(allowNetwork: Bool) -> [String] {
        ["start", warmContainerName(allowNetwork: allowNetwork)]
    }

    public static func dockerStartArguments(containerName: String) -> [String] {
        ["start", containerName]
    }

    public static func dockerInspectContainerRunningArguments(containerName: String) -> [String] {
        ["inspect", "-f", "{{.State.Running}}", containerName]
    }

    /// Exec into the warm container and run python reading the execution script from stdin.
    public static func dockerExecArguments(allowNetwork: Bool) -> [String] {
        dockerExecArguments(containerName: warmContainerName(allowNetwork: allowNetwork))
    }

    /// Exec into a specific pool container.
    public static func dockerExecArguments(containerName: String) -> [String] {
        ["exec", "-i", containerName, baselinePythonPath, "-I", "-u", "-"]
    }

    /// Detects a docker-unavailable condition from stderr and exit code.
    /// Returns a human-readable message, or nil if docker ran normally.
    public static func dockerUnavailableMessage(stderr: String, exitCode: Int32) -> String? {
        let lowered = stderr.lowercased()
        if exitCode == 127 {
            return "Docker Desktop is required for python_script_exec. Install Docker Desktop and ensure `docker` is available in PATH."
        }
        if lowered.contains("connect to the docker daemon") ||
            lowered.contains("cannot connect to the docker daemon") ||
            lowered.contains("error during connect") ||
            lowered.contains("docker.sock") ||
            lowered.contains("/var/run/docker.sock") {
            return "Docker Desktop appears unavailable. Start Docker Desktop and retry python_script_exec."
        }
        return nil
    }
}

/// Direct-process docker CLI runner (`Process` → `env docker …`).
///
/// **Not used by production Derrick processes.** MCPService and the UI app must
/// not spawn docker themselves (sandbox + single helper egress path).
///
/// - Production MCP: `MCPServiceDockerHelperRunner` (helper peer XPC)
/// - Production UI prewarm: `XPCDockerRunner` (helper Application XPC)
/// - This type: MCPServer package tests and intentional non-sandboxed tooling only
public final class DockerPythonScriptRunner: PythonScriptRunner, @unchecked Sendable {
    private final class EnsureState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func isCompleted() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return completed
        }

        func markCompleted() {
            lock.lock()
            defer { lock.unlock() }
            completed = true
        }
    }

    private let ensureState = EnsureState()

    public init(dockerImage: String = DockerScriptPreparer.defaultImage) {
        _ = dockerImage
    }

    public func run(
        script: String,
        timeoutSeconds: Int,
        allowNetwork: Bool,
        pythonPackages: [String],
        allowDependencyInstall: Bool
    ) async throws -> PythonScriptExecutionResult {
        let totalStarted = Date()
        let ensureStarted = Date()
        try await ensureWarmEnvironment()
        let ensureMS = PythonScriptPhaseTiming.elapsedMS(from: ensureStarted)

        let extras = DockerScriptPreparer.extraPackages(from: pythonPackages)
        let executionScript = DockerScriptPreparer.makeExecutionScript(
            script: script,
            installPackages: extras,
            allowDependencyInstall: allowDependencyInstall,
            nonBaselinePackages: extras
        )
        guard let stdinData = executionScript.data(using: .utf8) else {
            throw NSError(domain: "MCPServer", code: 503, userInfo: [NSLocalizedDescriptionKey: "Failed to encode execution script."])
        }

        let execStarted = Date()
        let effectiveTimeout = DockerScriptPreparer.effectiveScriptTimeoutSeconds(requested: timeoutSeconds)
        let processResult: (stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) =
            try await DockerNetworkContainerPool.shared.withContainer(
                allowNetwork: allowNetwork,
                executor: Self.dockerCLIExecutor
            ) { containerName in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: DockerHostLaunch.envExecutablePath)
                process.arguments = DockerHostLaunch.dockerCLIArguments(
                    DockerScriptPreparer.dockerExecArguments(containerName: containerName)
                )
                process.environment = DockerScriptPreparer.processEnvironment()

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    throw NSError(
                        domain: "MCPServer",
                        code: 503,
                        userInfo: [NSLocalizedDescriptionKey: "Docker Desktop is required for python_script_exec. Install Docker Desktop and ensure `docker` is available in PATH."]
                    )
                }

                stdinPipe.fileHandleForWriting.write(stdinData)
                stdinPipe.fileHandleForWriting.closeFile()

                let timedOut = await Self.waitForDockerExit(process: process, timeoutSeconds: effectiveTimeout)
                if timedOut { process.terminate() }

                let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                let exitCode = timedOut ? -1 : process.terminationStatus
                return (
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self),
                    exitCode: exitCode,
                    timedOut: timedOut
                )
            }
        let execMS = PythonScriptPhaseTiming.elapsedMS(from: execStarted)
        let totalMS = PythonScriptPhaseTiming.elapsedMS(from: totalStarted)
        let scriptMetrics = PythonScriptPhaseTiming.scriptMetrics(script)

        if let dockerMessage = DockerScriptPreparer.dockerUnavailableMessage(
            stderr: processResult.stderr,
            exitCode: processResult.exitCode
        ) {
            throw NSError(domain: "MCPServer", code: 503, userInfo: [NSLocalizedDescriptionKey: dockerMessage])
        }

        let phaseTiming = PythonScriptPhaseTiming(
            ensureMS: ensureMS,
            execMS: execMS,
            totalMS: totalMS,
            scriptCharCount: scriptMetrics.chars,
            scriptLineCount: scriptMetrics.lines,
            wrapperCharCount: executionScript.utf8.count
        )

        return PythonScriptExecutionResult.runnerOutcome(
            timedOut: processResult.timedOut,
            exitCode: processResult.exitCode,
            stdout: processResult.stdout,
            stderr: processResult.stderr,
            durationMS: totalMS,
            phaseTiming: phaseTiming
        )
    }

    private static let dockerCLIExecutor: DockerCLIExecutor = { arguments, timeoutSeconds in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: DockerHostLaunch.envExecutablePath)
        process.arguments = DockerHostLaunch.dockerCLIArguments(arguments)
        process.environment = DockerScriptPreparer.processEnvironment()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let timedOut = await waitForDockerExit(process: process, timeoutSeconds: timeoutSeconds)
        if timedOut { process.terminate() }
        let stdout = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        return DockerCLIResult(
            exitCode: timedOut ? -1 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func waitForDockerExit(process: Process, timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(max(timeoutSeconds, 1)))
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return process.isRunning
    }

    private func ensureWarmEnvironment() async throws {
        if ensureState.isCompleted() { return }

        try await ensureVolume(DockerScriptPreparer.pipCacheVolume)
        try await ensureVolume(DockerScriptPreparer.packagesVolume)
        try await ensureBaselineImage()
        try await DockerNetworkContainerPool.shared.prewarm(executor: Self.dockerCLIExecutor)

        ensureState.markCompleted()
    }

    private func ensureVolume(_ name: String) async throws {
        let inspect = try await runDocker(DockerScriptPreparer.dockerVolumeInspectArguments(name), timeoutSeconds: 15)
        if inspect.exitCode == 0 { return }
        _ = try await runDocker(DockerScriptPreparer.dockerVolumeCreateArguments(name), timeoutSeconds: 15)
    }

    private func ensureBaselineImage() async throws {
        let inspect = try await runDocker(DockerScriptPreparer.dockerImageInspectArguments(DockerScriptPreparer.defaultImage), timeoutSeconds: 15)
        if inspect.exitCode == 0 { return }

        let parentInspect = try await runDocker(DockerScriptPreparer.dockerImageInspectArguments(DockerScriptPreparer.parentImage), timeoutSeconds: 15)
        if parentInspect.exitCode != 0 {
            let pull = try await runDocker(DockerScriptPreparer.dockerPullArguments(DockerScriptPreparer.parentImage), timeoutSeconds: 300)
            if pull.exitCode != 0 {
                throw NSError(domain: "MCPServer", code: 503, userInfo: [NSLocalizedDescriptionKey: "Failed to pull parent image \(DockerScriptPreparer.parentImage)."])
            }
        }

        let dockerfile = DockerScriptPreparer.baselineDockerfile
        let build = try await runDocker(
            DockerScriptPreparer.dockerBuildBaselineArguments(),
            stdin: dockerfile.data(using: .utf8) ?? Data(),
            timeoutSeconds: 300
        )
        if build.exitCode != 0 {
            let stderr = String(decoding: build.stderr, as: UTF8.self)
            throw NSError(domain: "MCPServer", code: 503, userInfo: [NSLocalizedDescriptionKey: "Failed to build baseline image: \(stderr)"])
        }
    }

    private struct LocalDockerResult {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    private func runDocker(_ args: [String], stdin: Data = Data(), timeoutSeconds: Int) async throws -> LocalDockerResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: DockerHostLaunch.envExecutablePath)
        process.arguments = DockerHostLaunch.dockerCLIArguments(args)
        process.environment = DockerScriptPreparer.processEnvironment()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        if !stdin.isEmpty {
            stdinPipe.fileHandleForWriting.write(stdin)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        let timedOut = await waitForExit(process: process, timeoutSeconds: timeoutSeconds)
        if timedOut { process.terminate() }

        let stdout = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        return LocalDockerResult(stdout: stdout, stderr: stderr, exitCode: timedOut ? -1 : process.terminationStatus)
    }

    private func waitForExit(process: Process, timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(max(timeoutSeconds, 1)))
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return process.isRunning
    }
}

