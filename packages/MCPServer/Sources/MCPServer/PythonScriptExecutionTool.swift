import Foundation
import LLMAgentClient
import MCP

private let ReviewerSystemPrompt = """
You are a security reviewer for Python script tool declarations.
Evaluate whether script, mode, description, reason, and user prompt align.
expected_effects is only needed if the request mode is write.
Baseline packages include `requests`, `beautifulsoup4`, `chardet`, and `lxml`.

Isolation rules (deny if violated):
- The container reuses a warm environment across runs. `/tmp` and `/var/tmp` are wiped between runs by the harness; scripts must not rely on prior-run temp files.
- `/packages` is a shared persistent directory for installed Python packages only (pip/uv target and importable package trees).
- Deny or flag as a concern any script that writes, saves, downloads, or dumps non-package artifacts under `/packages` (e.g. JSON/CSV/logs/images/user data, open(..., 'w') under /packages, pathlib writes, shutil copies into /packages).
- Installing declared python_packages into `/packages` via the harness is allowed; scripts themselves must not treat `/packages` as general scratch or output storage.

Return only valid JSON with this exact schema:
{
  "alignedWithRequest": true|false,
  "confidence": 0.0-1.0,
  "suggestedAction": "allow"|"confirm"|"deny",
  "concerns": ["..."],
  "summary": "short explanation"
}
"""

public struct PythonScriptExecutionArguments: Sendable {
    public enum Mode: String, Sendable {
        case readonly
        case write
    }

    public let mode: Mode
    public let description: String
    public let reason: String
    public let script: String
    public let userPrompt: String?
    public let expectedEffects: [String]
    public let pythonPackages: [String]
    public let allowDependencyInstall: Bool
    public let timeoutSeconds: Int
    public let allowNetwork: Bool

    public init(
        mode: Mode,
        description: String,
        reason: String,
        script: String,
        userPrompt: String?,
        expectedEffects: [String],
        pythonPackages: [String],
        allowDependencyInstall: Bool,
        timeoutSeconds: Int,
        allowNetwork: Bool
    ) {
        self.mode = mode
        self.description = description
        self.reason = reason
        self.script = script
        self.userPrompt = userPrompt
        self.expectedEffects = expectedEffects
        self.pythonPackages = pythonPackages
        self.allowDependencyInstall = allowDependencyInstall
        self.timeoutSeconds = timeoutSeconds
        self.allowNetwork = allowNetwork
    }
}

public enum PythonScriptExecutionStatus: String, Codable, Sendable {
    case completed
    case failed
    case timeout
    case blocked
}

public enum PythonScriptExecutionDecision: String, Codable, Sendable {
    case allow
    case deny
    case confirm
}

public struct PythonScriptExecutionResult: Codable, Sendable {
    public let status: PythonScriptExecutionStatus
    public let decision: PythonScriptExecutionDecision
    public let verifier: String
    public let validationFindings: [String]
    public let reviewerAssessment: PythonScriptReviewAssessment?
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let durationMS: Int

    public init(
        status: PythonScriptExecutionStatus,
        decision: PythonScriptExecutionDecision,
        verifier: String,
        validationFindings: [String],
        reviewerAssessment: PythonScriptReviewAssessment?,
        stdout: String,
        stderr: String,
        exitCode: Int32,
        timedOut: Bool,
        durationMS: Int
    ) {
        self.status = status
        self.decision = decision
        self.verifier = verifier
        self.validationFindings = validationFindings
        self.reviewerAssessment = reviewerAssessment
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.durationMS = durationMS
    }
}

public struct PythonScriptReviewAssessment: Codable, Sendable {
    public let alignedWithRequest: Bool
    public let confidence: Double
    public let suggestedAction: String
    public let concerns: [String]
    public let summary: String

    public init(
        alignedWithRequest: Bool,
        confidence: Double,
        suggestedAction: String,
        concerns: [String],
        summary: String
    ) {
        self.alignedWithRequest = alignedWithRequest
        self.confidence = confidence
        self.suggestedAction = suggestedAction
        self.concerns = concerns
        self.summary = summary
    }
}

public protocol PythonScriptRunner: Sendable {
    func run(
        script: String,
        timeoutSeconds: Int,
        allowNetwork: Bool,
        pythonPackages: [String],
        allowDependencyInstall: Bool
    ) async throws -> PythonScriptExecutionResult
}

public protocol PythonScriptReviewer: Sendable {
    var name: String { get }
    func review(_ args: PythonScriptExecutionArguments) async throws -> PythonScriptReviewAssessment
}

public struct OpenAIPythonScriptReviewer: PythonScriptReviewer {
    public let name: String
    private let model: OpenAIModel
    private let client: OpenAIAgentClient

    public init(apiKey: String, model: OpenAIModel = .gpt5Mini) {
        self.name = "openai-\(model.rawValue)"
        self.model = model
        self.client = OpenAIAgentClient(provider: OpenAIProvider(apiKey: apiKey))
    }

    public static func fromEnvironment(
        variable: String = "OPENAI_API_KEY",
        model: OpenAIModel = .gpt5Mini
    ) -> OpenAIPythonScriptReviewer? {
        guard let apiKey = ProcessInfo.processInfo.environment[variable], !apiKey.isEmpty else {
            return nil
        }
        return OpenAIPythonScriptReviewer(apiKey: apiKey, model: model)
    }

    public func review(_ args: PythonScriptExecutionArguments) async throws -> PythonScriptReviewAssessment {
        print("[PythonScriptExecutionTool] Reviewer request started: model=\(model.rawValue), mode=\(args.mode.rawValue), packages=\(args.pythonPackages.count), allowNetwork=\(args.allowNetwork), timeoutSeconds=\(args.timeoutSeconds)")
        let request = AgentRequest(
            messages: [
                .init(role: .system, content: ReviewerSystemPrompt),
                .init(role: .user, content: Self.reviewInput(from: args))
            ],
            temperature: 0
        )
        let stream = client.stream(request, model: model)
        var completion = ""
        for try await chunk in stream {
            completion += chunk
        }
        let assessment = try Self.decodeAssessment(from: completion)
        print("[PythonScriptExecutionTool] Reviewer outcome: aligned=\(assessment.alignedWithRequest), confidence=\(assessment.confidence), suggestedAction=\(assessment.suggestedAction), concerns=\(assessment.concerns.count), summary=\(assessment.summary)")
        return assessment
    }

    private static func reviewInput(from args: PythonScriptExecutionArguments) -> String {
        let payload: [String: Any] = [
            "mode": args.mode.rawValue,
            "description": args.description,
            "reason": args.reason,
            "script": args.script,
            "user_prompt": args.userPrompt ?? "",
            "expected_effects": args.expectedEffects,
            "python_packages": args.pythonPackages,
            "allow_dependency_install": args.allowDependencyInstall,
            "allow_network": args.allowNetwork,
            "timeout_seconds": args.timeoutSeconds
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let json = String(decoding: data, as: UTF8.self)
        return "Review this declared python script tool call payload:\n\(json)"
    }

    private static func decodeAssessment(from response: String) throws -> PythonScriptReviewAssessment {
        let normalized = normalizeJSONPayload(response)
        guard let data = normalized.data(using: .utf8) else {
            throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Reviewer returned invalid UTF-8."])
        }
        return try JSONDecoder().decode(PythonScriptReviewAssessment.self, from: data)
    }

    private static func normalizeJSONPayload(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```"),
           let start = trimmed.range(of: "{"),
           let end = trimmed.range(of: "}", options: .backwards),
           start.lowerBound < end.upperBound {
            return String(trimmed[start.lowerBound..<end.upperBound])
        }
        return trimmed
    }
}

public struct GeminiPythonScriptReviewer: PythonScriptReviewer {
    public let name: String
    private let model: GeminiModel
    private let client: GeminiAgentClient

    public init(apiKey: String, model: GeminiModel = .gemini25FlashLite) {
        self.name = "gemini-\(model.rawValue)"
        self.model = model
        self.client = GeminiAgentClient(provider: GeminiProvider(apiKey: apiKey))
    }

    public static func fromEnvironment(
        variable: String = "GEMINI_API_KEY",
        model: GeminiModel = .gemini25FlashLite
    ) -> GeminiPythonScriptReviewer? {
        guard let apiKey = ProcessInfo.processInfo.environment[variable], !apiKey.isEmpty else {
            return nil
        }
        return GeminiPythonScriptReviewer(apiKey: apiKey, model: model)
    }

    public func review(_ args: PythonScriptExecutionArguments) async throws -> PythonScriptReviewAssessment {
        print("[PythonScriptExecutionTool] Reviewer request started: model=\(model.rawValue), mode=\(args.mode.rawValue), packages=\(args.pythonPackages.count), allowNetwork=\(args.allowNetwork), timeoutSeconds=\(args.timeoutSeconds)")
        let request = AgentRequest(
            messages: [
                .init(role: .system, content: ReviewerSystemPrompt),
                .init(role: .user, content: Self.reviewInput(from: args))
            ],
            temperature: 0
        )
        let stream = client.stream(request, model: model)
        var completion = ""
        for try await chunk in stream {
            completion += chunk
        }
        let assessment = try Self.decodeAssessment(from: completion)
        print("[PythonScriptExecutionTool] Reviewer outcome: aligned=\(assessment.alignedWithRequest), confidence=\(assessment.confidence), suggestedAction=\(assessment.suggestedAction), concerns=\(assessment.concerns.count), summary=\(assessment.summary)")
        return assessment
    }

    private static func reviewInput(from args: PythonScriptExecutionArguments) -> String {
        let payload: [String: Any] = [
            "mode": args.mode.rawValue,
            "description": args.description,
            "reason": args.reason,
            "script": args.script,
            "user_prompt": args.userPrompt ?? "",
            "expected_effects": args.expectedEffects,
            "python_packages": args.pythonPackages,
            "allow_dependency_install": args.allowDependencyInstall,
            "allow_network": args.allowNetwork,
            "timeout_seconds": args.timeoutSeconds
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let json = String(decoding: data, as: UTF8.self)
        return "Review this declared python script tool call payload:\n\(json)"
    }

    private static func decodeAssessment(from response: String) throws -> PythonScriptReviewAssessment {
        let normalized = normalizeJSONPayload(response)
        guard let data = normalized.data(using: .utf8) else {
            throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Reviewer returned invalid UTF-8."])
        }
        return try JSONDecoder().decode(PythonScriptReviewAssessment.self, from: data)
    }

    private static func normalizeJSONPayload(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```"),
           let start = trimmed.range(of: "{"),
           let end = trimmed.range(of: "}", options: .backwards),
           start.lowerBound < end.upperBound {
            return String(trimmed[start.lowerBound..<end.upperBound])
        }
        return trimmed
    }
}

/// Utilities for preparing docker run arguments and Python execution scripts.
/// Used by both `DockerPythonScriptRunner` and the XPC-based runner in the main app.
public enum DockerScriptPreparer {
    /// Parent image used when building the local baseline image.
    public static let parentImage = "ghcr.io/astral-sh/uv:debian"

    /// Bump when baseline package set or Dockerfile changes so prewarm rebuilds.
    public static let baselineImageVersion = "2"

    /// Local image with baseline packages baked in (`docker build` on prewarm if missing).
    public static var defaultImage: String {
        "derrick-python:baseline-\(baselineImageVersion)"
    }

    /// Virtualenv inside the baseline image (avoids Debian "externally managed" system Python).
    public static let baselineVenvPath = "/opt/derrick-venv"
    public static var baselinePythonPath: String {
        "\(baselineVenvPath)/bin/python"
    }

    public static let pipCacheVolume = "derrick-pip-cache"
    public static let packagesVolume = "derrick-python-packages"
    public static let warmContainerNetwork = "derrick-python-runner-net"
    public static let warmContainerNoNetwork = "derrick-python-runner-nonet"

    public static let baselinePackages: Set<String> = [
        "requests",
        "beautifulsoup4",
        "chardet",
        "lxml"
    ]

    public static var baselineDockerfile: String {
        let packages = baselinePackages.sorted().joined(separator: " ")
        // Debian/uv images mark system Python as externally managed (PEP 668).
        // Install baseline deps into a dedicated venv and run scripts with that interpreter.
        return """
        FROM \(parentImage)
        RUN uv venv \(baselineVenvPath) \\
         && uv pip install --python \(baselinePythonPath) --no-cache \(packages)
        ENV VIRTUAL_ENV=\(baselineVenvPath)
        ENV PATH="\(baselineVenvPath)/bin:$$PATH"
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

    /// Hold process for warm containers. Absolute path required: the uv/debian image is
    /// minimal and does not put `sleep` on PATH (bare `sleep` → exec not found / exit 127).
    public static let warmContainerHoldBinary = "/bin/sleep"
    public static let warmContainerHoldArg = "infinity"

    /// Create a long-lived warm container. Does not start it.
    ///
    /// Overrides image default `Cmd` (`/usr/local/bin/uv`) so the container stays up for
    /// later `docker exec` of script runs.
    public static func dockerCreateWarmContainerArguments(allowNetwork: Bool) -> [String] {
        let name = warmContainerName(allowNetwork: allowNetwork)
        var args = [
            "create",
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
            "--entrypoint", warmContainerHoldBinary,
            defaultImage,
            warmContainerHoldArg
        ]
        args.insert(contentsOf: allowNetwork ? ["--network", "bridge"] : ["--network", "none"], at: 1)
        return args
    }

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
        let started = Date()
        try await ensureWarmEnvironment()

        let extras = DockerScriptPreparer.extraPackages(from: pythonPackages)
        let executionScript = DockerScriptPreparer.makeExecutionScript(
            script: script,
            installPackages: extras,
            allowDependencyInstall: allowDependencyInstall,
            nonBaselinePackages: extras
        )

        try await ensureWarmContainer(allowNetwork: allowNetwork)

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
        let elapsed = Int(Date().timeIntervalSince(started) * 1000.0)
        let exitCode = timedOut ? -1 : process.terminationStatus

        if let dockerMessage = DockerScriptPreparer.dockerUnavailableMessage(stderr: stderr, exitCode: exitCode) {
            throw NSError(domain: "MCPServer", code: 503, userInfo: [NSLocalizedDescriptionKey: dockerMessage])
        }

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
            durationMS: elapsed
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
            || path != DockerScriptPreparer.warmContainerHoldBinary

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

public enum PythonScriptExecutionVerifier {
    public static func validate(_ args: PythonScriptExecutionArguments) -> [String] {
        var findings: [String] = []

        if args.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append("Missing description.")
        }
        if args.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append("Missing reason.")
        }
        if args.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append("Script is empty.")
        }
        if args.timeoutSeconds <= 0 || args.timeoutSeconds > 300 {
            findings.append("timeout_seconds must be between 1 and 300.")
        }
        if args.mode == .write && args.expectedEffects.isEmpty {
            findings.append("Write mode requires expected_effects.")
        }
        let normalizedPackages = normalizePackages(args.pythonPackages)
        let invalidPackageNames = normalizedPackages.filter { !isValidPackageName($0) }
        if !invalidPackageNames.isEmpty {
            findings.append("Invalid python_packages values: \(invalidPackageNames.joined(separator: ", ")).")
        }
        let installPackages = DockerScriptPreparer.extraPackages(from: args.pythonPackages)
        if !installPackages.isEmpty && !args.allowDependencyInstall {
            findings.append("Requested python_packages require allow_dependency_install=true: \(installPackages.joined(separator: ", ")).")
        }
        if !installPackages.isEmpty && !args.allowNetwork {
            findings.append("Installing non-baseline python_packages requires allow_network=true.")
        }

        if args.mode == .readonly {
            let readonlyViolations = readonlyViolations(in: args.script)
            findings.append(contentsOf: readonlyViolations)
        }
        if !args.allowNetwork {
            let networkViolations = networkViolations(in: args.script)
            findings.append(contentsOf: networkViolations)
        }
        findings.append(contentsOf: packagesVolumeViolations(in: args.script))

        if let prompt = args.userPrompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let score = relevanceScore(prompt: prompt, details: "\(args.description) \(args.reason)")
            if score < 0.05 {
                findings.append("Low prompt relevance score; description/reason do not align with user request.")
            }
        }

        return findings
    }

    private static func readonlyViolations(in script: String) -> [String] {
        let patterns: [(String, String)] = [
            (#"(?m)\b(open|Path)\s*\(.+,\s*["'][wa\+]"# , "Readonly mode cannot open files for writing."),
            (#"(?m)\b(os\.remove|os\.rename|os\.rmdir|os\.mkdir|os\.makedirs|shutil\.)\b"#, "Readonly mode cannot mutate filesystem."),
            (#"(?m)\b(subprocess\.|os\.system|exec\(|eval\()"#, "Readonly mode cannot execute nested commands.")
        ]

        return patterns.compactMap { pattern, message in
            script.range(of: pattern, options: .regularExpression) != nil ? message : nil
        }
    }

    private static func networkViolations(in script: String) -> [String] {
        let patterns: [(String, String)] = [
            (#"(?m)\b(requests\.|httpx\.|urllib\.|socket\.)"#, "Network access in script requires allow_network=true.")
        ]

        return patterns.compactMap { pattern, message in
            script.range(of: pattern, options: .regularExpression) != nil ? message : nil
        }
    }

    /// Blocks treating the shared `/packages` volume as general output/scratch storage.
    /// Package installs go through the harness; user scripts must not write non-package artifacts there.
    private static func packagesVolumeViolations(in script: String) -> [String] {
        let message = "Scripts must not write non-package files under /packages (shared package volume only)."
        let patterns: [String] = [
            #"(?m)open\s*\(\s*['\"]/packages/"#,
            #"(?m)Path\s*\(\s*['\"]/packages/"#,
            #"(?m)['\"]/packages/[^'\"]*['\"]\s*,\s*['\"][wax\+]"#,
            #"(?m)(shutil\.(copy|copy2|copyfile|copytree|move)|os\.(replace|rename))\s*\([^)]*/packages/"#,
            #"(?m)(pathlib\.Path\s*\(\s*['\"]/packages/[^'\"]*['\"]\s*\)\s*\.\s*(write_text|write_bytes|mkdir|touch|open))"#,
            #"(?m)json\.dump\s*\([^)]*/packages/"#,
            #"(?m)(to_csv|to_json|to_parquet|savefig|imwrite)\s*\(\s*['\"]/packages/"#
        ]

        for pattern in patterns {
            if script.range(of: pattern, options: .regularExpression) != nil {
                return [message]
            }
        }
        return []
    }

    private static func relevanceScore(prompt: String, details: String) -> Double {
        let promptTokens = Set(tokenize(prompt))
        let detailTokens = Set(tokenize(details))
        guard !promptTokens.isEmpty else { return 1.0 }
        let overlap = promptTokens.intersection(detailTokens).count
        return Double(overlap) / Double(promptTokens.count)
    }

    private static func tokenize(_ input: String) -> [String] {
        input
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 }
    }

    private static func normalizePackages(_ packages: [String]) -> [String] {
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

    private static func isValidPackageName(_ package: String) -> Bool {
        package.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    }
}

public extension MCPServerHost {
    func registerPythonScriptExecutionTool(
        name: String = "python_script_exec",
        description: String = "Run declared Python script in a constrained Docker container after verification.",
        runner: any PythonScriptRunner = DockerPythonScriptRunner(),
        reviewer: (any PythonScriptReviewer)? = GeminiPythonScriptReviewer.fromEnvironment(),
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) async {
        await registryRegisterPythonTool(
            name: name,
            description: description,
            runner: runner,
            reviewer: reviewer,
            logger: logger
        )
    }

    private func registryRegisterPythonTool(
        name: String,
        description: String,
        runner: any PythonScriptRunner,
        reviewer: (any PythonScriptReviewer)?,
        logger: @escaping @Sendable (String) -> Void
    ) async {
        let inputSchema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "mode": .object([
                    "type": .string("string"),
                    "enum": .array([.string("readonly"), .string("write")]),
                    "description": .string("Execution mode declaration. readonly forbids write-like behavior.")
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("Human description of what the script does.")
                ]),
                "reason": .object([
                    "type": .string("string"),
                    "description": .string("Why this script is needed.")
                ]),
                "script": .object([
                    "type": .string("string"),
                    "description": .string("Python script source code.")
                ]),
                "user_prompt": .object([
                    "type": .string("string"),
                    "description": .string("Original user prompt to validate relevance.")
                ]),
                "expected_effects": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Declared intended effects (required for write mode).")
                ]),
                "python_packages": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Optional dependency names (PyPI packages). Baseline packages are curated and can be installed without allow_dependency_install.")
                ]),
                "allow_dependency_install": .object([
                    "type": .string("boolean"),
                    "description": .string("Allow per-run pip install of non-baseline packages. Requires allow_network=true.")
                ]),
                "timeout_seconds": .object([
                    "type": .string("number"),
                    "description": .string("Execution timeout in seconds (1...300).")
                ]),
                "allow_network": .object([
                    "type": .string("boolean"),
                    "description": .string("Enable container network access when the user request requires fetching live/current web data or installing packages.")
                ])
            ]),
            "required": .array([.string("mode"), .string("allow_network"), .string("description"), .string("reason"), .string("script")])
        ])

        await registerTool(
            name: name,
            description: description,
            inputSchema: inputSchema
        ) { arguments in
            let parsed = try Self.parsePythonScriptExecutionArguments(arguments)
            let staticFindings = PythonScriptExecutionVerifier.validate(parsed)
            logger("staticFindings \(staticFindings.map(\.debugDescription).joined(separator: "\n"))")
            var findings = staticFindings
            var verifierName = "static-check-v1"
            var assessment: PythonScriptReviewAssessment?

            if let reviewer {
                do {
                    logger("[PythonScriptExecutionTool] Reviewer request started: \(reviewer.name)")
                    assessment = try await reviewer.review(parsed)
                    verifierName += "+\(reviewer.name)"
                } catch {
                    logger("[PythonScriptExecutionTool] Reviewer failed: \(error.localizedDescription)")
                    print("[PythonScriptExecutionTool] reviewer failed: \(error)")
                    let message = "Reviewer failed: \(error.localizedDescription)"
                    findings.append(message)
                }
            } else if parsed.mode == .write {
                let message = "Write mode requires configured reviewer."
                findings.append(message)
            }

            if !findings.isEmpty || assessment?.alignedWithRequest == false {
                let denied = PythonScriptExecutionResult(
                    status: .blocked,
                    decision: .deny,
                    verifier: verifierName,
                    validationFindings: findings,
                    reviewerAssessment: assessment,
                    stdout: "",
                    stderr: "",
                    exitCode: -1,
                    timedOut: false,
                    durationMS: 0
                )
                return Self.encodeJSON(denied)
            }

            var result = try await runner.run(
                script: parsed.script,
                timeoutSeconds: parsed.timeoutSeconds,
                allowNetwork: parsed.allowNetwork,
                pythonPackages: parsed.pythonPackages,
                allowDependencyInstall: parsed.allowDependencyInstall
            )
            result = PythonScriptExecutionResult(
                status: result.status,
                decision: result.decision,
                verifier: verifierName,
                validationFindings: findings,
                reviewerAssessment: assessment,
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode,
                timedOut: result.timedOut,
                durationMS: result.durationMS
            )
            return Self.encodeJSON(result)
        }
    }

    private static func parsePythonScriptExecutionArguments(_ arguments: [String: Value]) throws -> PythonScriptExecutionArguments {
        guard
            let modeRaw = arguments["mode"]?.stringValue,
            let mode = PythonScriptExecutionArguments.Mode(rawValue: modeRaw.lowercased()),
            let description = arguments["description"]?.stringValue,
            let reason = arguments["reason"]?.stringValue,
            let script = arguments["script"]?.stringValue
        else {
            throw NSError(
                domain: "MCPServer",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Missing required fields: mode, description, reason, script."]
            )
        }

        let userPrompt = arguments["user_prompt"]?.stringValue
        let expectedEffects = (arguments["expected_effects"]?.arrayValue ?? []).compactMap { $0.stringValue }
        let pythonPackages = (arguments["python_packages"]?.arrayValue ?? []).compactMap { $0.stringValue }
        let allowDependencyInstall = arguments["allow_dependency_install"]?.boolValue ?? false
        let timeoutSeconds = arguments["timeout_seconds"]?.intValue ?? 30
        let allowNetwork = arguments["allow_network"]?.boolValue ?? false

        return PythonScriptExecutionArguments(
            mode: mode,
            description: description,
            reason: reason,
            script: script,
            userPrompt: userPrompt,
            expectedEffects: expectedEffects,
            pythonPackages: pythonPackages,
            allowDependencyInstall: allowDependencyInstall,
            timeoutSeconds: timeoutSeconds,
            allowNetwork: allowNetwork
        )
    }
}
