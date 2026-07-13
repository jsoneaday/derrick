import Foundation
import LLMAgentClient
import MCP

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

public struct PythonScriptExecutionResult: Codable, Sendable {
    public let status: String
    public let decision: String
    public let verifier: String
    public let findings: [String]
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let durationMS: Int

    public init(
        status: String,
        decision: String,
        verifier: String,
        findings: [String],
        stdout: String,
        stderr: String,
        exitCode: Int32,
        timedOut: Bool,
        durationMS: Int
    ) {
        self.status = status
        self.decision = decision
        self.verifier = verifier
        self.findings = findings
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
                .init(role: .system, content: Self.systemPrompt),
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

    private static let systemPrompt = """
    You are a strict security reviewer for Python tool declarations.
    Evaluate whether script, mode, description, reason, expected effects, and user prompt align.
    Return only valid JSON with this exact schema:
    {
      "alignedWithRequest": true|false,
      "confidence": 0.0-1.0,
      "suggestedAction": "allow"|"confirm"|"deny",
      "concerns": ["..."],
      "summary": "short explanation"
    }
    """

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
                .init(role: .system, content: Self.systemPrompt),
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

    private static let systemPrompt = """
    You are a strict security reviewer for Python tool declarations.
    Evaluate whether script, mode, description, reason, expected effects, and user prompt align.
    Return only valid JSON with this exact schema:
    {
      "alignedWithRequest": true|false,
      "confidence": 0.0-1.0,
      "suggestedAction": "allow"|"confirm"|"deny",
      "concerns": ["..."],
      "summary": "short explanation"
    }
    """

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
    public static let defaultImage = "ghcr.io/astral-sh/uv:debian"

    public static let baselinePackages: Set<String> = [
        "requests",
        "beautifulsoup4",
        "chardet",
        "lxml"
    ]

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

    /// Minimal environment for docker CLI to locate daemon and config.
    public static func processEnvironment() -> [String: String] {
        [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory()
        ]
    }

    /// Builds the Python wrapper script that installs packages and executes user code.
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
        import subprocess
        import sys

        install_packages = json.loads('''\(packagesJSON)''')
        non_baseline_packages = json.loads('''\(nonBaselineJSON)''')
        allow_dependency_install = \(installEnabled)

        # Pre-execution Syntax Check
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
            # Install to /packages (an executable tmpfs) because the container runs --read-only
            # and native Python extensions must be loaded from an executable filesystem.
            # Try to use 'uv' first for lightning-fast Rust-powered installations, fall back to pip
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

    /// Arguments to pass to the `docker` command (everything after `docker`).
    public static func dockerRunArguments(image: String, allowNetwork: Bool) -> [String] {
        var args = [
            "run",
            "--rm",
            "--init",
            "--read-only",
            "--tmpfs", "/tmp:rw,noexec,nosuid,size=256m",
            "--tmpfs", "/var/tmp:rw,noexec,nosuid,size=64m",
            "--tmpfs", "/packages:rw,nosuid,exec,size=256m",
            "--pids-limit", "64",
            "--cpus", "1.0",
            "--memory", "512m",
            "--security-opt", "no-new-privileges",
            "--cap-drop", "ALL",
            "--ulimit", "nofile=128:128",
            "-v", "derrick-pip-cache:/root/.cache",
            "-i",
            image,
            "python3", "-I", "-u", "-"
        ]
        args.insert(contentsOf: allowNetwork ? ["--network", "bridge"] : ["--network", "none"], at: 1)
        return args
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
public struct DockerPythonScriptRunner: PythonScriptRunner {
    private let dockerImage: String

    public init(dockerImage: String = DockerScriptPreparer.defaultImage) {
        self.dockerImage = dockerImage
    }

    public func run(
        script: String,
        timeoutSeconds: Int,
        allowNetwork: Bool,
        pythonPackages: [String],
        allowDependencyInstall: Bool
    ) async throws -> PythonScriptExecutionResult {
        let started = Date()
        let allPackages = pythonPackages + Array(DockerScriptPreparer.baselinePackages)
        let normalizedPackages = DockerScriptPreparer.normalizePackages(allPackages)
        let nonBaselinePackages = normalizedPackages.filter { !DockerScriptPreparer.baselinePackages.contains($0) }
        let executionScript = DockerScriptPreparer.makeExecutionScript(
            script: script,
            installPackages: normalizedPackages,
            allowDependencyInstall: allowDependencyInstall,
            nonBaselinePackages: nonBaselinePackages
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker"] + DockerScriptPreparer.dockerRunArguments(image: dockerImage, allowNetwork: allowNetwork)
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
            status: timedOut ? "timeout" : (exitCode == 0 ? "completed" : "failed"),
            decision: (timedOut || exitCode != 0) ? "deny" : "allow",
            verifier: "static-check-v1",
            findings: [],
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            timedOut: timedOut,
            durationMS: elapsed
        )
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
        let installPackages = normalizedPackages.filter { !DockerScriptPreparer.baselinePackages.contains($0) }
        if !installPackages.isEmpty && !args.allowDependencyInstall {
            findings.append("Requested python_packages require allow_dependency_install=true: \(installPackages.joined(separator: ", ")).")
        }
        if !normalizedPackages.isEmpty && !args.allowNetwork {
            findings.append("Installing python_packages requires allow_network=true.")
        }

        if args.mode == .readonly {
            let readonlyViolations = readonlyViolations(in: args.script)
            findings.append(contentsOf: readonlyViolations)
        }
        if !args.allowNetwork {
            let networkViolations = networkViolations(in: args.script)
            findings.append(contentsOf: networkViolations)
        }

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
            "required": .array([.string("mode"), .string("description"), .string("reason"), .string("script")])
        ])

        await registerTool(
            name: name,
            description: description
            ,
            inputSchema: inputSchema
        ) { arguments in
            let parsed = try Self.parsePythonScriptExecutionArguments(arguments)
            let staticFindings = PythonScriptExecutionVerifier.validate(parsed)
            var findings = staticFindings
            var blockingFindings = staticFindings
            var verifierName = "static-check-v1"

            if let reviewer {
                do {
                    logger("[PythonScriptExecutionTool] Reviewer request started: \(reviewer.name)")
                    let assessment = try await reviewer.review(parsed)
                    verifierName += "+\(reviewer.name)"
                    findings.append(contentsOf: assessment.concerns)
                    findings.append("Reviewer summary: \(assessment.summary)")
                    findings.append("Reviewer outcome: aligned=\(assessment.alignedWithRequest), confidence=\(String(format: "%.2f", assessment.confidence)), suggestedAction=\(assessment.suggestedAction)")
                    logger("[PythonScriptExecutionTool] Reviewer outcome: aligned=\(assessment.alignedWithRequest), confidence=\(String(format: "%.2f", assessment.confidence)), suggestedAction=\(assessment.suggestedAction), concerns=\(assessment.concerns.count), summary=\(assessment.summary)")

                    if assessment.suggestedAction.lowercased() == "deny", assessment.confidence >= 0.55 {
                        blockingFindings.append("Reviewer denied with confidence \(String(format: "%.2f", assessment.confidence)).")
                    }
                    if !assessment.alignedWithRequest, assessment.confidence >= 0.60 {
                        blockingFindings.append("Reviewer marked declaration misaligned with user request.")
                    }
                    if parsed.mode == .write {
                        if assessment.confidence < 0.55 {
                            blockingFindings.append("Reviewer confidence too low for write mode.")
                        }
                        if assessment.suggestedAction.lowercased() == "confirm" {
                            blockingFindings.append("Reviewer requires manual confirmation for write mode.")
                        }
                    }
                } catch {
                    logger("[PythonScriptExecutionTool] Reviewer failed: \(error.localizedDescription)")
                    print("[PythonScriptExecutionTool] reviewer failed: \(error)")
                    let message = "Reviewer failed: \(error.localizedDescription)"
                    findings.append(message)
                    if parsed.mode == .write {
                        blockingFindings.append("Write mode requires reviewer success.")
                    }
                }
            } else if parsed.mode == .write {
                let message = "Write mode requires configured reviewer."
                findings.append(message)
                blockingFindings.append(message)
            }

            if !blockingFindings.isEmpty {
                let denied = PythonScriptExecutionResult(
                    status: "blocked",
                    decision: "deny",
                    verifier: verifierName,
                    findings: findings,
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
                findings: findings,
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
