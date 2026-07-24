//
//  DockerHelper.swift
//  MCPServer
//
//  Created by David Choi on 7/24/26.
//

import Foundation

/// Utilities for preparing docker run arguments and Python execution scripts.
/// Used by both `DockerPythonScriptRunner` and the XPC-based runner in the main app.
public enum DockerScriptPreparer {
    /// Parent image used when building the local baseline image.
    public static let parentImage = "ghcr.io/astral-sh/uv:debian"

    /// Bump when baseline package set or Dockerfile changes so prewarm rebuilds.
    public static let baselineImageVersion = "4"

    /// Local image with baseline packages baked in (`docker build` on prewarm if missing).
    public static var defaultImage: String {
        "derrick-python:baseline-\(baselineImageVersion)"
    }

    /// Virtualenv inside the baseline image (avoids Debian "externally managed" system Python).
    public static let baselineVenvPath = "/opt/derrick-venv"
    public static var baselinePythonPath: String {
        "\(baselineVenvPath)/bin/python"
    }

    /// Net-container hold process: installs OUTPUT iptables policy then sleeps.
    public static let forcedEgressHoldPath = "/usr/local/bin/derrick-net-hold"

    public static let pipCacheVolume = "derrick-pip-cache"
    public static let packagesVolume = "derrick-python-packages"
    /// Bump when create-args change (e.g. forced egress) so warm containers recreate.
    public static let warmContainerGeneration = "px2"
    public static var warmContainerNetwork: String { "derrick-runner-net-\(warmContainerGeneration)" }
    public static var warmContainerNoNetwork: String { "derrick-runner-nonet-\(warmContainerGeneration)" }

    public static let baselinePackages: Set<String> = [
        "requests",
        "beautifulsoup4",
        "chardet",
        "lxml"
    ]

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
        let packages = baselinePackages.sorted().joined(separator: " ")
        let holdB64 = Data(forcedEgressHoldScript.utf8).base64EncodedString()
        // Debian/uv images mark system Python as externally managed (PEP 668).
        // Net hold script forces OUTPUT via host proxy only (item 4).
        return """
        FROM \(parentImage)
        RUN apt-get update \\
         && apt-get install -y --no-install-recommends iptables iproute2 ca-certificates \\
         && rm -rf /var/lib/apt/lists/* \\
         && uv venv \(baselineVenvPath) \\
         && uv pip install --python \(baselinePythonPath) --no-cache \(packages) \\
         && echo \(holdB64) | base64 -d > \(forcedEgressHoldPath) \\
         && chmod 755 \(forcedEgressHoldPath)
        ENV VIRTUAL_ENV=\(baselineVenvPath)
        ENV PATH="\(baselineVenvPath)/bin:$$PATH"
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

    /// Packages that are not baked into the baseline image (installed into the packages volume).
    public static func extraPackages(from requested: [String]) -> [String] {
        normalizePackages(requested).filter { !baselinePackages.contains($0) }
    }

    public static func warmContainerName(allowNetwork: Bool) -> String {
        allowNetwork ? warmContainerNetwork : warmContainerNoNetwork
    }

    /// Minimal environment for docker CLI to locate daemon and config.
    public static func processEnvironment() -> [String: String] {
        [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory()
        ]
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
    public static func dockerCreateWarmContainerArguments(allowNetwork: Bool) -> [String] {
        let name = warmContainerName(allowNetwork: allowNetwork)
        if allowNetwork {
            var options: [String] = [
                "create",
                "--network", "bridge",
                "--name", name,
                "--init",
                "--read-only",
                "--tmpfs", "/tmp:rw,noexec,nosuid,size=256m",
                "--tmpfs", "/var/tmp:rw,noexec,nosuid,size=64m",
                "--tmpfs", "/run:rw,nosuid,size=16m",
                "--pids-limit", "64",
                "--cpus", "1.0",
                "--memory", "512m",
                "--security-opt", "no-new-privileges",
                "--cap-drop", "ALL",
                "--cap-add", "NET_ADMIN",
                "--ulimit", "nofile=128:128",
                "-v", "\(pipCacheVolume):/root/.cache",
                "-v", "\(packagesVolume):/packages",
                "-e", "DERRICK_PROXY_PORT=18080",
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
            "--name", name,
            "--init",
            "--read-only",
            "--tmpfs", "/tmp:rw,noexec,nosuid,size=256m",
            "--tmpfs", "/var/tmp:rw,noexec,nosuid,size=64m",
            "--pids-limit", "64",
            "--cpus", "1.0",
            "--memory", "512m",
            "--security-opt", "no-new-privileges",
            "--cap-drop", "ALL",
            "--ulimit", "nofile=128:128",
            "-v", "\(pipCacheVolume):/root/.cache",
            "-v", "\(packagesVolume):/packages",
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

    /// Exec into the warm container and run python reading the execution script from stdin.
    public static func dockerExecArguments(allowNetwork: Bool) -> [String] {
        ["exec", "-i", warmContainerName(allowNetwork: allowNetwork), baselinePythonPath, "-I", "-u", "-"]
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

/// Direct-process docker runner. Used in tests and non-sandboxed contexts.
/// In the sandboxed app, use `XPCDockerRunner` from the main target instead.
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

        let extras = DockerScriptPreparer.extraPackages(from: pythonPackages)
        let executionScript = DockerScriptPreparer.makeExecutionScript(
            script: script,
            installPackages: extras,
            allowDependencyInstall: allowDependencyInstall,
            nonBaselinePackages: extras
        )

        try await ensureWarmContainer(allowNetwork: allowNetwork)
        let ensureMS = PythonScriptPhaseTiming.elapsedMS(from: ensureStarted)

        let execStarted = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker"] + DockerScriptPreparer.dockerExecArguments(allowNetwork: allowNetwork)
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

        if let data = executionScript.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        let timedOut = await waitForExit(process: process, timeoutSeconds: timeoutSeconds)
        if timedOut { process.terminate() }

        let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
        let execMS = PythonScriptPhaseTiming.elapsedMS(from: execStarted)
        let totalMS = PythonScriptPhaseTiming.elapsedMS(from: totalStarted)
        let exitCode = timedOut ? -1 : process.terminationStatus
        let scriptMetrics = PythonScriptPhaseTiming.scriptMetrics(script)

        if let dockerMessage = DockerScriptPreparer.dockerUnavailableMessage(stderr: stderr, exitCode: exitCode) {
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

        return PythonScriptExecutionResult(
            status: timedOut ? .timeout : (exitCode == 0 ? .completed : .failed),
            decision: (timedOut || exitCode != 0) ? .deny : .allow,
            verifier: "static-check-v1",
            validationFindings: [],
            reviewerAssessment: nil,
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            timedOut: timedOut,
            durationMS: totalMS,
            phaseTiming: phaseTiming
        )
    }

    private func ensureWarmEnvironment() async throws {
        if ensureState.isCompleted() { return }

        try await ensureVolume(DockerScriptPreparer.pipCacheVolume)
        try await ensureVolume(DockerScriptPreparer.packagesVolume)
        try await ensureBaselineImage()
        try await ensureWarmContainer(allowNetwork: true)
        try await ensureWarmContainer(allowNetwork: false)

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

    private func ensureWarmContainer(allowNetwork: Bool) async throws {
        try await recreateWarmContainerIfNeeded(allowNetwork: allowNetwork)
        try await startWarmContainerIfNeeded(allowNetwork: allowNetwork)
    }

    private func recreateWarmContainerIfNeeded(allowNetwork: Bool) async throws {
        let imageInspect = try await runDocker(
            DockerScriptPreparer.dockerInspectContainerImageArguments(allowNetwork: allowNetwork),
            timeoutSeconds: 15
        )
        let pathInspect = try await runDocker(
            DockerScriptPreparer.dockerInspectContainerPathArguments(allowNetwork: allowNetwork),
            timeoutSeconds: 15
        )
        let imageName = String(decoding: imageInspect.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = String(decoding: pathInspect.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let needsRecreate =
            imageInspect.exitCode != 0
            || imageName != DockerScriptPreparer.defaultImage
            || path != DockerScriptPreparer.warmContainerHoldPath(allowNetwork: allowNetwork)

        guard needsRecreate else { return }

        _ = try await runDocker(
            DockerScriptPreparer.dockerRmForceArguments(container: DockerScriptPreparer.warmContainerName(allowNetwork: allowNetwork)),
            timeoutSeconds: 15
        )
        let create = try await runDocker(
            DockerScriptPreparer.dockerCreateWarmContainerArguments(allowNetwork: allowNetwork),
            timeoutSeconds: 30
        )
        if create.exitCode != 0 {
            let stderr = String(decoding: create.stderr, as: UTF8.self)
            throw NSError(domain: "MCPServer", code: 503, userInfo: [NSLocalizedDescriptionKey: "Failed to create warm container: \(stderr)"])
        }
    }

    private func startWarmContainerIfNeeded(allowNetwork: Bool) async throws {
        let runningInspect = try await runDocker(
            DockerScriptPreparer.dockerInspectContainerRunningArguments(allowNetwork: allowNetwork),
            timeoutSeconds: 15
        )
        let running = String(decoding: runningInspect.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if running == "true" { return }

        let start = try await runDocker(DockerScriptPreparer.dockerStartArguments(allowNetwork: allowNetwork), timeoutSeconds: 30)
        if start.exitCode != 0 {
            let stderr = String(decoding: start.stderr, as: UTF8.self)
            throw NSError(domain: "MCPServer", code: 503, userInfo: [NSLocalizedDescriptionKey: "Failed to start warm container: \(stderr)"])
        }

        let verify = try await runDocker(
            DockerScriptPreparer.dockerInspectContainerRunningArguments(allowNetwork: allowNetwork),
            timeoutSeconds: 15
        )
        let ok = String(decoding: verify.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ok != "true" {
            let err = String(decoding: start.stderr, as: UTF8.self)
            throw NSError(
                domain: "MCPServer",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "Warm container is not running after start. \(err)"]
            )
        }
    }

    private struct LocalDockerResult {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    private func runDocker(_ args: [String], stdin: Data = Data(), timeoutSeconds: Int) async throws -> LocalDockerResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker"] + args
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

