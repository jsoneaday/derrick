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
    public let timeoutSeconds: Int
    public let allowNetwork: Bool

    public init(
        mode: Mode,
        description: String,
        reason: String,
        script: String,
        userPrompt: String?,
        expectedEffects: [String],
        timeoutSeconds: Int,
        allowNetwork: Bool
    ) {
        self.mode = mode
        self.description = description
        self.reason = reason
        self.script = script
        self.userPrompt = userPrompt
        self.expectedEffects = expectedEffects
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
    func run(script: String, timeoutSeconds: Int, allowNetwork: Bool) async throws -> PythonScriptExecutionResult
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
        return try Self.decodeAssessment(from: completion)
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

public struct DockerPythonScriptRunner: PythonScriptRunner {
    private let dockerImage: String

    public init(dockerImage: String = "python:3.12-alpine") {
        self.dockerImage = dockerImage
    }

    public func run(script: String, timeoutSeconds: Int, allowNetwork: Bool) async throws -> PythonScriptExecutionResult {
        let started = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = dockerRunArguments(image: dockerImage, timeoutSeconds: timeoutSeconds, allowNetwork: allowNetwork)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        if let data = script.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        let timedOut = await waitForExit(process: process, timeoutSeconds: timeoutSeconds)
        if timedOut {
            process.terminate()
        }

        let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000.0)

        return PythonScriptExecutionResult(
            status: timedOut ? "timeout" : "completed",
            decision: timedOut ? "deny" : "allow",
            verifier: "static-check-v1",
            findings: [],
            stdout: stdout,
            stderr: stderr,
            exitCode: timedOut ? -1 : process.terminationStatus,
            timedOut: timedOut,
            durationMS: elapsed
        )
    }

    private func dockerRunArguments(image: String, timeoutSeconds: Int, allowNetwork: Bool) -> [String] {
        var args = [
            "docker",
            "run",
            "--rm",
            "--init",
            "--read-only",
            "--tmpfs", "/tmp:rw,noexec,nosuid,size=64m",
            "--tmpfs", "/var/tmp:rw,noexec,nosuid,size=64m",
            "--pids-limit", "64",
            "--cpus", "1.0",
            "--memory", "512m",
            "--security-opt", "no-new-privileges",
            "--cap-drop", "ALL",
            "--ulimit", "nofile=128:128",
            "-i",
            image,
            "python3",
            "-I",
            "-u",
            "-"
        ]

        if allowNetwork {
            args.insert(contentsOf: ["--network", "bridge"], at: 3)
        } else {
            args.insert(contentsOf: ["--network", "none"], at: 3)
        }

        _ = timeoutSeconds
        return args
    }

    private func waitForExit(process: Process, timeoutSeconds: Int) async -> Bool {
        let timeout = max(timeoutSeconds, 1)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))

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
        if args.allowNetwork {
            findings.append("Network-enabled execution is disallowed by default policy.")
        }
        if args.mode == .write && args.expectedEffects.isEmpty {
            findings.append("Write mode requires expected_effects.")
        }

        if args.mode == .readonly {
            let readonlyViolations = readonlyViolations(in: args.script)
            findings.append(contentsOf: readonlyViolations)
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
            (#"(?m)\b(subprocess\.|os\.system|exec\(|eval\()"#, "Readonly mode cannot execute nested commands."),
            (#"(?m)\b(requests\.|httpx\.|urllib\.|socket\.)"#, "Readonly mode cannot access network.")
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
}

public extension MCPServerHost {
    func registerPythonScriptExecutionTool(
        name: String = "python_script_exec",
        description: String = "Run declared Python script in a constrained Docker container after verification.",
        runner: any PythonScriptRunner = DockerPythonScriptRunner(),
        reviewer: (any PythonScriptReviewer)? = OpenAIPythonScriptReviewer.fromEnvironment()
    ) async {
        await registryRegisterPythonTool(name: name, description: description, runner: runner, reviewer: reviewer)
    }

    private func registryRegisterPythonTool(
        name: String,
        description: String,
        runner: any PythonScriptRunner,
        reviewer: (any PythonScriptReviewer)?
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
                "timeout_seconds": .object([
                    "type": .string("number"),
                    "description": .string("Execution timeout in seconds (1...300).")
                ]),
                "allow_network": .object([
                    "type": .string("boolean"),
                    "description": .string("Must be false by default policy.")
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
                    let assessment = try await reviewer.review(parsed)
                    verifierName += "+\(reviewer.name)"
                    findings.append(contentsOf: assessment.concerns)
                    findings.append("Reviewer summary: \(assessment.summary)")

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
                allowNetwork: parsed.allowNetwork
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
        let timeoutSeconds = arguments["timeout_seconds"]?.intValue ?? 30
        let allowNetwork = arguments["allow_network"]?.boolValue ?? false

        return PythonScriptExecutionArguments(
            mode: mode,
            description: description,
            reason: reason,
            script: script,
            userPrompt: userPrompt,
            expectedEffects: expectedEffects,
            timeoutSeconds: timeoutSeconds,
            allowNetwork: allowNetwork
        )
    }
}
