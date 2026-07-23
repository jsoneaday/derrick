import Foundation
import LLMAgentClient
import MCP

private let ReviewerSystemPrompt = """
You are a security reviewer for Python script tool declarations.

FAIL-FAST (mandatory):
- Apply checks in order. As soon as ANY single check fails, stop immediately.
- Do NOT continue scanning for more issues after the first failure.
- On first failure: return suggestedAction "deny", alignedWithRequest false or true as appropriate, concerns with only that one failing reason, and a short summary. No essays.
- Only if every check passes: return suggestedAction "allow" with a brief summary (1-2 sentences). concerns may be empty or at most one minor operational note.

Checks (stop at first failure):
1) Script, mode, description, reason, and user prompt are consistent (intent alignment).
2) expected_effects is only required when mode is write.
3) No writes of non-package artifacts under /packages (scratch/output storage).
4) No reliance on prior-run /tmp or /var/tmp contents.
5) Network: host/LAN/private targets and host.docker.internal are infrastructure-denied; do not allow scripts that primarily target them. Outbound public network is otherwise constrained by an egress allowlist (you need not re-list every domain).
6) Baseline packages available without install: requests, beautifulsoup4, chardet, lxml. Non-baseline installs require allow_dependency_install.

Return only valid JSON with this exact schema:
{
  "alignedWithRequest": true|false,
  "confidence": 0.0-1.0,
  "suggestedAction": "allow"|"deny",
  "concerns": ["..."],
  "summary": "short explanation"
}
Prefer "deny" over "confirm". Do not use "confirm".
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

/// Sub-phase timings inside the LLM security reviewer call.
public struct PythonScriptReviewerTiming: Codable, Sendable, Equatable {
    public var ttfbMS: Int
    public var streamMS: Int
    public var decodeMS: Int
    public var totalMS: Int
    public var requestChars: Int
    public var responseChars: Int
    public var chunkCount: Int
    public var model: String

    public init(
        ttfbMS: Int = 0,
        streamMS: Int = 0,
        decodeMS: Int = 0,
        totalMS: Int = 0,
        requestChars: Int = 0,
        responseChars: Int = 0,
        chunkCount: Int = 0,
        model: String = ""
    ) {
        self.ttfbMS = ttfbMS
        self.streamMS = streamMS
        self.decodeMS = decodeMS
        self.totalMS = totalMS
        self.requestChars = requestChars
        self.responseChars = responseChars
        self.chunkCount = chunkCount
        self.model = model
    }

    public var summaryLine: String {
        "reviewer_model=\(model.isEmpty ? "?" : model) reviewer_ttfb_ms=\(ttfbMS) reviewer_stream_ms=\(streamMS) reviewer_decode_ms=\(decodeMS) reviewer_total_ms=\(totalMS) reviewer_request_chars=\(requestChars) reviewer_response_chars=\(responseChars) reviewer_chunks=\(chunkCount)"
    }
}

public struct PythonScriptReviewOutcome: Sendable {
    public let assessment: PythonScriptReviewAssessment
    public let timing: PythonScriptReviewerTiming

    public init(assessment: PythonScriptReviewAssessment, timing: PythonScriptReviewerTiming) {
        self.assessment = assessment
        self.timing = timing
    }
}

/// Wall-clock phase timings for `python_script_exec` bottleneck analysis.
public struct PythonScriptPhaseTiming: Codable, Sendable, Equatable {
    public var staticValidateMS: Int
    public var reviewerMS: Int
    public var ensureMS: Int
    public var execMS: Int
    public var totalMS: Int
    public var scriptCharCount: Int
    public var scriptLineCount: Int
    public var wrapperCharCount: Int
    public var reviewerTtfbMS: Int
    public var reviewerStreamMS: Int
    public var reviewerDecodeMS: Int
    public var reviewerRequestChars: Int
    public var reviewerResponseChars: Int
    public var reviewerChunkCount: Int
    public var reviewerModel: String

    public init(
        staticValidateMS: Int = 0,
        reviewerMS: Int = 0,
        ensureMS: Int = 0,
        execMS: Int = 0,
        totalMS: Int = 0,
        scriptCharCount: Int = 0,
        scriptLineCount: Int = 0,
        wrapperCharCount: Int = 0,
        reviewerTtfbMS: Int = 0,
        reviewerStreamMS: Int = 0,
        reviewerDecodeMS: Int = 0,
        reviewerRequestChars: Int = 0,
        reviewerResponseChars: Int = 0,
        reviewerChunkCount: Int = 0,
        reviewerModel: String = ""
    ) {
        self.staticValidateMS = staticValidateMS
        self.reviewerMS = reviewerMS
        self.ensureMS = ensureMS
        self.execMS = execMS
        self.totalMS = totalMS
        self.scriptCharCount = scriptCharCount
        self.scriptLineCount = scriptLineCount
        self.wrapperCharCount = wrapperCharCount
        self.reviewerTtfbMS = reviewerTtfbMS
        self.reviewerStreamMS = reviewerStreamMS
        self.reviewerDecodeMS = reviewerDecodeMS
        self.reviewerRequestChars = reviewerRequestChars
        self.reviewerResponseChars = reviewerResponseChars
        self.reviewerChunkCount = reviewerChunkCount
        self.reviewerModel = reviewerModel
    }

    public mutating func applyReviewerTiming(_ timing: PythonScriptReviewerTiming) {
        reviewerMS = timing.totalMS
        reviewerTtfbMS = timing.ttfbMS
        reviewerStreamMS = timing.streamMS
        reviewerDecodeMS = timing.decodeMS
        reviewerRequestChars = timing.requestChars
        reviewerResponseChars = timing.responseChars
        reviewerChunkCount = timing.chunkCount
        reviewerModel = timing.model
    }

    public var summaryLine: String {
        let base = "static_ms=\(staticValidateMS) reviewer_ms=\(reviewerMS) ensure_ms=\(ensureMS) exec_ms=\(execMS) total_ms=\(totalMS) script_chars=\(scriptCharCount) script_lines=\(scriptLineCount) wrapper_chars=\(wrapperCharCount)"
        guard !reviewerModel.isEmpty || reviewerTtfbMS > 0 || reviewerStreamMS > 0 || reviewerResponseChars > 0 else {
            return base
        }
        return base + " reviewer_model=\(reviewerModel.isEmpty ? "?" : reviewerModel) reviewer_ttfb_ms=\(reviewerTtfbMS) reviewer_stream_ms=\(reviewerStreamMS) reviewer_decode_ms=\(reviewerDecodeMS) reviewer_request_chars=\(reviewerRequestChars) reviewer_response_chars=\(reviewerResponseChars) reviewer_chunks=\(reviewerChunkCount)"
    }

    public static func scriptMetrics(_ script: String) -> (chars: Int, lines: Int) {
        let chars = script.utf8.count
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).count
        return (chars, lines)
    }

    public static func elapsedMS(from start: Date, to end: Date = Date()) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000.0).rounded()))
    }
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
    public let phaseTiming: PythonScriptPhaseTiming?

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
        durationMS: Int,
        phaseTiming: PythonScriptPhaseTiming? = nil
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
        self.phaseTiming = phaseTiming
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
    func review(_ args: PythonScriptExecutionArguments) async throws -> PythonScriptReviewOutcome
}

enum PythonScriptReviewerRuntime {
    static func reviewInput(from args: PythonScriptExecutionArguments) -> String {
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

    static func decodeAssessment(from response: String) throws -> PythonScriptReviewAssessment {
        let normalized = normalizeJSONPayload(response)
        guard let data = normalized.data(using: .utf8) else {
            throw NSError(domain: "MCPServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Reviewer returned invalid UTF-8."])
        }
        return try JSONDecoder().decode(PythonScriptReviewAssessment.self, from: data)
    }

    static func normalizeJSONPayload(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```"),
           let start = trimmed.range(of: "{"),
           let end = trimmed.range(of: "}", options: .backwards),
           start.lowerBound < end.upperBound {
            return String(trimmed[start.lowerBound..<end.upperBound])
        }
        return trimmed
    }

    static func runStreamedReview(
        modelLabel: String,
        args: PythonScriptExecutionArguments,
        stream: AsyncThrowingStream<String, Error>
    ) async throws -> PythonScriptReviewOutcome {
        let userContent = reviewInput(from: args)
        let requestChars = ReviewerSystemPrompt.utf8.count + userContent.utf8.count
        print("[PythonScriptExecutionTool] Reviewer request started: model=\(modelLabel), mode=\(args.mode.rawValue), packages=\(args.pythonPackages.count), allowNetwork=\(args.allowNetwork), timeoutSeconds=\(args.timeoutSeconds), request_chars=\(requestChars)")

        let requestStarted = Date()
        var firstChunkAt: Date?
        var lastChunkAt: Date?
        var chunkCount = 0
        var completion = ""

        for try await chunk in stream {
            let now = Date()
            if firstChunkAt == nil {
                firstChunkAt = now
            }
            lastChunkAt = now
            chunkCount += 1
            completion += chunk
        }

        let streamEnded = Date()
        let ttfbMS: Int
        let streamMS: Int
        if let first = firstChunkAt {
            ttfbMS = PythonScriptPhaseTiming.elapsedMS(from: requestStarted, to: first)
            streamMS = PythonScriptPhaseTiming.elapsedMS(from: first, to: lastChunkAt ?? streamEnded)
        } else {
            // No chunks: entire wait is queue/error path.
            ttfbMS = PythonScriptPhaseTiming.elapsedMS(from: requestStarted, to: streamEnded)
            streamMS = 0
        }

        let decodeStarted = Date()
        let assessment = try decodeAssessment(from: completion)
        let decodeMS = PythonScriptPhaseTiming.elapsedMS(from: decodeStarted)
        let totalMS = PythonScriptPhaseTiming.elapsedMS(from: requestStarted)

        let timing = PythonScriptReviewerTiming(
            ttfbMS: ttfbMS,
            streamMS: streamMS,
            decodeMS: decodeMS,
            totalMS: totalMS,
            requestChars: requestChars,
            responseChars: completion.utf8.count,
            chunkCount: chunkCount,
            model: modelLabel
        )

        print("[PythonScriptExecutionTool] Reviewer outcome: aligned=\(assessment.alignedWithRequest), confidence=\(assessment.confidence), suggestedAction=\(assessment.suggestedAction), concerns=\(assessment.concerns.count), summary=\(assessment.summary)")
        print("[PythonScriptExecutionTool] Reviewer timing: \(timing.summaryLine)")
        return PythonScriptReviewOutcome(assessment: assessment, timing: timing)
    }
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

    public func review(_ args: PythonScriptExecutionArguments) async throws -> PythonScriptReviewOutcome {
        let userContent = PythonScriptReviewerRuntime.reviewInput(from: args)
        let request = AgentRequest(
            messages: [
                .init(role: .system, content: ReviewerSystemPrompt),
                .init(role: .user, content: userContent)
            ],
            temperature: 0
        )
        let stream = client.stream(request, model: model)
        return try await PythonScriptReviewerRuntime.runStreamedReview(
            modelLabel: model.rawValue,
            args: args,
            stream: stream
        )
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

    public func review(_ args: PythonScriptExecutionArguments) async throws -> PythonScriptReviewOutcome {
        let userContent = PythonScriptReviewerRuntime.reviewInput(from: args)
        let request = AgentRequest(
            messages: [
                .init(role: .system, content: ReviewerSystemPrompt),
                .init(role: .user, content: userContent)
            ],
            temperature: 0
        )
        let stream = client.stream(request, model: model)
        return try await PythonScriptReviewerRuntime.runStreamedReview(
            modelLabel: model.rawValue,
            args: args,
            stream: stream
        )
    }
}

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
            findings.append(contentsOf: networkRequiredViolations(in: args.script))
        }
        findings.append(contentsOf: hostOrPrivateTargetViolations(in: args.script))
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

    private static func networkRequiredViolations(in script: String) -> [String] {
        let patterns: [(String, String)] = [
            (#"(?m)\b(requests\.|httpx\.|urllib\.|socket\.)"#, "Network access in script requires allow_network=true.")
        ]
        return patterns.compactMap { pattern, message in
            script.range(of: pattern, options: .regularExpression) != nil ? message : nil
        }
    }

    private static func hostOrPrivateTargetViolations(in script: String) -> [String] {
        let patterns: [(String, String)] = [
            (#"(?mi)host\.docker\.internal"#, "Scripts must not target host.docker.internal (blocked by egress policy)."),
            (#"(?m)\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3})\b"#, "Scripts must not hardcode private network addresses.")
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
            let toolStarted = Date()
            let parsed = try Self.parsePythonScriptExecutionArguments(arguments)
            let scriptMetrics = PythonScriptPhaseTiming.scriptMetrics(parsed.script)
            logger(
                "[python_script_exec] script size: chars=\(scriptMetrics.chars) lines=\(scriptMetrics.lines)"
            )

            let staticStarted = Date()
            let staticFindings = PythonScriptExecutionVerifier.validate(parsed)
            let staticValidateMS = PythonScriptPhaseTiming.elapsedMS(from: staticStarted)
            logger("staticFindings \(staticFindings.map(\.debugDescription).joined(separator: "\n"))")
            logger("[python_script_exec timing] static_ms=\(staticValidateMS)")
            var findings = staticFindings
            var verifierName = "static-check-v1"
            var assessment: PythonScriptReviewAssessment?
            var reviewerTiming = PythonScriptReviewerTiming()

            // Short-circuit: static failure or offline container — no LLM reviewer.
            // DestinationPolicy / egress proxy still apply at runtime when network is used.
            var needsLLMReview = false
            if !staticFindings.isEmpty {
                logger("[python_script_exec] skipping LLM reviewer: static validation failed")
                verifierName += "+llm-skipped-static"
            } else if !parsed.allowNetwork {
                logger("[python_script_exec] skipping LLM reviewer: allow_network=false (container-isolated)")
                verifierName += "+llm-skipped-offline"
            } else if let reviewer {
                needsLLMReview = true
                do {
                    logger("[PythonScriptExecutionTool] Reviewer request started: \(reviewer.name)")
                    let outcome = try await reviewer.review(parsed)
                    assessment = outcome.assessment
                    reviewerTiming = outcome.timing
                    verifierName += "+\(reviewer.name)"
                    logger("[python_script_exec timing] \(reviewerTiming.summaryLine)")
                } catch {
                    // Fail closed: any reviewer exception blocks execution.
                    logger("[PythonScriptExecutionTool] Reviewer failed: \(error.localizedDescription)")
                    print("[PythonScriptExecutionTool] reviewer failed: \(error)")
                    let message = "Reviewer failed: \(error.localizedDescription)"
                    findings.append(message)
                    assessment = nil
                }
            } else if parsed.mode == .write {
                let message = "Write mode with allow_network=true requires configured reviewer."
                findings.append(message)
            }

            // Fail closed only when an LLM review was required.
            if needsLLMReview {
                if assessment == nil {
                    findings.append("Reviewer did not return an assessment; execution denied.")
                } else if assessment?.alignedWithRequest == false {
                    findings.append("Reviewer marked script as not aligned with request; execution denied.")
                } else {
                    let action = (assessment?.suggestedAction ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if action == "deny" || action == "confirm" {
                        findings.append("Reviewer suggested \(action); execution denied.")
                    }
                }
            }

            if !findings.isEmpty {
                let totalMS = PythonScriptPhaseTiming.elapsedMS(from: toolStarted)
                var phaseTiming = PythonScriptPhaseTiming(
                    staticValidateMS: staticValidateMS,
                    ensureMS: 0,
                    execMS: 0,
                    totalMS: totalMS,
                    scriptCharCount: scriptMetrics.chars,
                    scriptLineCount: scriptMetrics.lines,
                    wrapperCharCount: 0
                )
                phaseTiming.applyReviewerTiming(reviewerTiming)
                logger("[python_script_exec timing] blocked \(phaseTiming.summaryLine)")
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
                    durationMS: totalMS,
                    phaseTiming: phaseTiming
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
            let totalMS = PythonScriptPhaseTiming.elapsedMS(from: toolStarted)
            var phaseTiming = result.phaseTiming ?? PythonScriptPhaseTiming()
            phaseTiming.staticValidateMS = staticValidateMS
            phaseTiming.totalMS = totalMS
            phaseTiming.scriptCharCount = scriptMetrics.chars
            phaseTiming.scriptLineCount = scriptMetrics.lines
            phaseTiming.applyReviewerTiming(reviewerTiming)
            logger("[python_script_exec timing] \(phaseTiming.summaryLine)")
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
                durationMS: totalMS,
                phaseTiming: phaseTiming
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
