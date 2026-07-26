import Foundation
import LLMAgentClient
import MCP
import MCPToolCatalog

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
        description: String? = nil,
        runner: any PythonScriptRunner = DockerPythonScriptRunner(),
        reviewer: (any PythonScriptReviewer)? = GeminiPythonScriptReviewer.fromEnvironment(),
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) async {
        await register(
            PythonScriptExecutionToolModule.makeRegistration(
                description: description,
                runner: runner,
                reviewer: reviewer,
                logger: logger
            )
        )
    }

    /// Shared execution body used by `PythonScriptExecutionToolModule` (keeps parse/verify helpers on host).
    static func runPythonScriptToolBody(
        arguments: [String: Value],
        runner: any PythonScriptRunner,
        reviewer: (any PythonScriptReviewer)?,
        logger: @escaping @Sendable (String) -> Void,
        toolStarted: Date
    ) async throws -> String {
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
                    logger("[PythonScriptExecutionTool] Reviewer assessment: \(outcome.assessment.summary)")
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
