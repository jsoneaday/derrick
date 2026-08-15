import DBRepository
import DockerRunnerXPC
import Foundation
import MCP
import MCPServer
import MCPToolCatalog
import Plugin
import PolicyUserInteraction
import ServiceContracts

enum PluginFactoryHost {
    static func registerTools(
        on server: MCPServerHost,
        repository: DBRepository,
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        reviewer: MCPServiceScriptReviewer,
        logger: @escaping @Sendable (String) -> Void
    ) async {
        await server.register(
            tool: .factoryBuild,
            description: AllowedMCPTool.factoryBuild.defaultDescription,
            inputSchema: objectSchema(
                ["goal": stringProp("What the plugin should do. Copy the user's request.")],
                required: ["goal"]
            )
        ) { args in
            try await build(args: args, repository: repository)
        }
        await server.register(
            tool: .factoryWritePackage,
            description: AllowedMCPTool.factoryWritePackage.defaultDescription,
            inputSchema: objectSchema([
                "plugin_id": stringProp("Plugin id (a-z, 0-9, dash)."),
                "version": stringProp("Semver-ish version, e.g. 1.0.0."),
                "description": stringProp("One-line description."),
                "handle": stringProp("TypeScript handle() source."),
                "dependencies": .object([
                    "type": .string("object"),
                    "description": .string("npm name → version."),
                ]),
                "volume_enabled": .object([
                    "type": .string("boolean"),
                    "description": .string("Opt-in /data volume. Default false."),
                ]),
            ], required: ["plugin_id", "description", "handle"])
        ) { args in
            try await writePackage(
                args: args,
                repository: repository,
                stdinExecutor: stdinExecutor
            )
        }
        await server.register(
            tool: .factoryReview,
            description: AllowedMCPTool.factoryReview.defaultDescription,
            inputSchema: objectSchema([:])
        ) { _ in
            try await review(
                repository: repository,
                reviewer: MCPServiceScriptReviewer(
                    name: "mcp-service-factory-reviewer",
                    systemPrompt: FactoryReviewerSystemPrompt
                ),
                logger: logger
            )
        }
        await server.register(
            tool: .factoryHarnessRun,
            description: AllowedMCPTool.factoryHarnessRun.defaultDescription,
            inputSchema: objectSchema([
                "fixtures": .object([
                    "type": .string("string"),
                    "description": .string("Optional JSON array of harness fixtures. Default uses the package fixtures."),
                ]),
            ])
        ) { args in
            try await harnessRun(
                args: args,
                repository: repository,
                stdinExecutor: stdinExecutor,
                logger: logger
            )
        }
        await server.register(
            tool: .factoryPromote,
            description: AllowedMCPTool.factoryPromote.defaultDescription,
            inputSchema: objectSchema([:])
        ) { _ in
            try await promote(
                repository: repository,
                stdinExecutor: stdinExecutor,
                logger: logger
            )
        }
        await server.register(
            tool: .factoryInstallSample,
            description: AllowedMCPTool.factoryInstallSample.defaultDescription,
            inputSchema: objectSchema([:])
        ) { _ in
            try await installSample(
                repository: repository,
                stdinExecutor: stdinExecutor,
                logger: logger
            )
        }
        await server.register(
            tool: .pluginList,
            description: AllowedMCPTool.pluginList.defaultDescription,
            inputSchema: objectSchema([:])
        ) { _ in
            try await listPlugins(repository: repository)
        }
        await server.register(
            tool: .pluginInvoke,
            description: AllowedMCPTool.pluginInvoke.defaultDescription,
            inputSchema: objectSchema([
                "plugin_id": stringProp("Installed plugin id."),
                "kind": stringProp("Event kind. Default manual."),
                "params": .object([
                    "type": .string("object"),
                    "description": .string("JSON object passed to handle as event.params. Not secrets. Max 16KiB."),
                ]),
            ], required: ["plugin_id"])
        ) { args in
            try await invoke(
                args: args,
                repository: repository,
                stdinExecutor: stdinExecutor,
                logger: logger
            )
        }
    }

    static func isFactoryEnabled(_ repository: DBRepository) async -> Bool {
        guard let raw = try? await repository.loadConfig(
            key: SoftwareFactorySettings.configKey,
            username: "ui",
            password: "ui"
        ),
              let data = raw.data(using: .utf8),
              let settings = try? JSONDecoder().decode(SoftwareFactorySettings.self, from: data) else {
            return false
        }
        return settings.enabled
    }

    static func searchVisible(
        tools: [MCPToolDescriptorDTO],
        repository: DBRepository,
        sessionID: String? = nil
    ) async -> [MCPToolDescriptorDTO] {
        let factoryOn = await isFactoryEnabled(repository)
        let installed = (try? await repository.listPlugins(includeDisabled: false)) ?? []
        let resolvedSession = sessionID
            ?? MCPServiceCallContext.shared.memorySessionKey?.sessionID
        let isFactorySession = FactorySessionID.isFactorySession(resolvedSession)
        return tools.filter { tool in
            if FactoryTurnGate.isHostDiscoveryTool(tool.name) {
                return false
            }
            switch tool.name {
            case AllowedMCPTool.factoryBuild.rawValue,
                 AllowedMCPTool.factoryWritePackage.rawValue,
                 AllowedMCPTool.factoryReview.rawValue,
                 AllowedMCPTool.factoryHarnessRun.rawValue,
                 AllowedMCPTool.factoryPromote.rawValue,
                 AllowedMCPTool.factoryInstallSample.rawValue:
                return factoryOn && isFactorySession
            case AllowedMCPTool.pluginInvoke.rawValue, AllowedMCPTool.pluginList.rawValue:
                return factoryOn || !installed.isEmpty
            default:
                return true
            }
        }
    }

    // MARK: - Tools

    private static func build(args: [String: Value], repository: DBRepository) async throws -> String {
        try await requireFactorySession(repository)
        let goal = args["goal"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !goal.isEmpty else {
            return encode([
                "ok": false,
                "error": "goal is required. Pass the user's request as goal.",
            ])
        }
        var draft = try await loadDraft(repository)
        draft.goal = goal
        try await saveDraft(draft, stage: "spec", repository: repository)
        return encode([
            "ok": true,
            "factory_session_id": try factorySessionID(),
            "stage": "spec",
            "goal": draft.goal,
            "next": "Write the package with factory.write_package (plugin_id, description, TypeScript handle). Then factory.review, factory.harness_run, factory.promote. Guest is TypeScript 7: export function handle(event: HandleEvent): HandleResult. HTTP only via netFetch.",
        ])
    }

    private static func writePackage(
        args: [String: Value],
        repository: DBRepository,
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult
    ) async throws -> String {
        try await requireFactorySession(repository)
        var draft = try await loadDraft(repository)
        let pluginID = args["plugin_id"]?.stringValue ?? ""
        let description = args["description"]?.stringValue ?? ""
        let handle = args["handle"]?.stringValue ?? ""
        guard !pluginID.isEmpty, !description.isEmpty, !handle.isEmpty else {
            return encode(["ok": false, "error": "plugin_id, description, and handle are required."])
        }
        _ = try PluginID(pluginID)
        var deps: [String: String] = [:]
        if let obj = args["dependencies"]?.objectValue {
            for (key, value) in obj {
                if let spec = value.stringValue { deps[key] = spec }
            }
        }
        draft.pluginID = pluginID
        draft.version = args["version"]?.stringValue?.isEmpty == false ? (args["version"]?.stringValue ?? "1.0.0") : "1.0.0"
        draft.description = description
        draft.handle = handle
        draft.dependencies = deps
        draft.volumeEnabled = args["volume_enabled"]?.boolValue ?? false
        draft.reviewPassed = false
        draft.reviewSummary = nil
        draft.harnessPassed = false
        draft.lastHarnessSummary = nil

        _ = try draft.pluginJSON()
        _ = try draft.runtimeJSON()
        let findings = ScriptJSVerifier.validate(script: handle, dependencies: deps)
        if !findings.isEmpty {
            try await saveDraft(draft, stage: "written", repository: repository)
            return encode(["ok": false, "stage": "written", "static_findings": findings])
        }
        let volume = try await writeStagingVolume(draft: draft, exec: stdinExecutor)
        draft.workspaceVolume = volume
        try await saveDraft(draft, stage: "written", pluginID: pluginID, repository: repository)
        return encode([
            "ok": true,
            "stage": "written",
            "plugin_id": pluginID,
            "version": draft.version,
            "workspace_volume": volume,
            "hash": try draft.contentHash().rawValue,
            "next": "Call factory.review, then factory.harness_run, then factory.promote.",
        ])
    }

    private static func review(
        repository: DBRepository,
        reviewer: MCPServiceScriptReviewer,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await requireFactorySession(repository)
        var draft = try await loadDraft(repository)
        guard !draft.handle.isEmpty, !draft.pluginID.isEmpty else {
            return encode(["ok": false, "error": "Write a package with factory.write_package first."])
        }
        var session = try await loadSession(repository)
        let caps = await loadFactoryCaps(repository)
        if caps.maxReviewer > 0, session.reviewerCalls >= caps.maxReviewer {
            return encode([
                "ok": false,
                "error": "Factory reviewer cap reached (\(caps.maxReviewer) per build). Raise it in Settings → Usage limits.",
            ])
        }
        session.reviewerCalls += 1
        session.updatedAt = .now
        try await repository.upsertFactorySession(session)

        let args = ScriptExecutionArguments(
            mode: .readonly,
            description: draft.description,
            reason: "Factory review for plugin \(draft.pluginID): \(draft.goal)",
            script: draft.handle,
            userPrompt: draft.goal.isEmpty ? draft.description : draft.goal,
            expectedEffects: [],
            packages: Array(draft.dependencies.keys),
            allowDependencyInstall: !draft.dependencies.isEmpty,
            timeoutSeconds: 60,
            allowNetwork: true
        )
        let outcome = try await reviewer.review(args)
        logger("[factory] reviewer: \(outcome.assessment.summary)")
        let action = outcome.assessment.suggestedAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let passed = outcome.assessment.alignedWithRequest != false && action != "deny" && action != "confirm"
        draft.reviewPassed = passed
        draft.reviewSummary = outcome.assessment.summary
        try await saveDraft(draft, stage: passed ? "reviewed" : "written", repository: repository)
        return encode([
            "ok": passed,
            "stage": passed ? "reviewed" : "written",
            "summary": outcome.assessment.summary,
            "concerns": outcome.assessment.concerns,
            "next": passed ? "Call factory.harness_run, then factory.promote." : "Fix the package and write again.",
        ])
    }

    private static func harnessRun(
        args: [String: Value],
        repository: DBRepository,
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await requireFactorySession(repository)
        var draft = try await loadDraft(repository)
        guard !draft.handle.isEmpty, !draft.pluginID.isEmpty else {
            return encode(["ok": false, "error": "Write a package with factory.write_package first."])
        }
        var session = try await loadSession(repository)
        let caps = await loadFactoryCaps(repository)
        if caps.maxHarness > 0, session.harnessRuns >= caps.maxHarness {
            return encode([
                "ok": false,
                "error": "Factory harness cap reached (\(caps.maxHarness) per build). Raise it in Settings → Usage limits.",
            ])
        }
        session.harnessRuns += 1
        session.updatedAt = .now
        try await repository.upsertFactorySession(session)

        if let fixtures = args["fixtures"]?.stringValue, !fixtures.isEmpty {
            draft.fixturesJSON = fixtures
        }
        let findings = ScriptJSVerifier.validate(script: draft.handle, dependencies: draft.dependencies)
        if !findings.isEmpty {
            draft.harnessPassed = false
            draft.lastHarnessSummary = findings.joined(separator: "; ")
            try await saveDraft(draft, stage: "written", repository: repository)
            return encode(["ok": false, "stage": "written", "static_findings": findings])
        }

        let result = try await ScriptExecutionRuntime.run(
            arguments: harnessArguments(draft: draft),
            stdinExecutor: stdinExecutor,
            reviewer: nil,
            logger: logger,
            reviewRequired: false,
            initialEvent: PluginHopEvent(kind: .harness, params: ["sample": .bool(true)])
        )
        let ok = harnessSucceeded(result)
        draft.harnessPassed = ok
        draft.lastHarnessSummary = ok ? "fixtures passed" : harnessError(result)
        try await saveDraft(draft, stage: ok ? "harnessed" : "written", repository: repository)
        return encode([
            "ok": ok,
            "stage": ok ? "harnessed" : "written",
            "summary": draft.lastHarnessSummary ?? "",
            "next": ok ? "Call factory.promote (user must approve install)." : "Fix the package and write again.",
        ])
    }

    private static func promote(
        repository: DBRepository,
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await requireFactorySession(repository)
        let draft = try await loadDraft(repository)
        guard draft.reviewPassed else {
            return encode(["ok": false, "error": "factory.review must pass before promote."])
        }
        guard draft.harnessPassed else {
            return encode(["ok": false, "error": "factory.harness_run must pass before promote."])
        }
        guard !draft.pluginID.isEmpty, !draft.handle.isEmpty else {
            return encode(["ok": false, "error": "No package to promote."])
        }

        let event = PolicyUserEventFactory.pluginInstall(
            pluginID: draft.pluginID,
            version: draft.version,
            summary: "Install \(draft.pluginID) \(draft.version)? \(draft.description)",
            detail: draft.installSummary(),
            payloadPreview: draft.handle,
            toolName: AllowedMCPTool.factoryPromote.rawValue
        )
        let decision = await PolicyDecisionRouting.requestDecision(event)
        switch decision {
        case .approved, .approvedOnce, .approvedPermanently:
            break
        case .denied, .dismissed, .timedOut:
            return encode(["ok": false, "error": "User did not approve install."])
        }

        let hash = try draft.contentHash()
        let manifest = try draft.pluginJSON()
        let runtime = try draft.runtimeJSON()
        let depsData = try JSONSerialization.data(withJSONObject: draft.dependencies)
        let depsJSON = String(decoding: depsData, as: UTF8.self)

        if let existing = try await repository.plugin(id: draft.pluginID),
           let currentID = existing.currentVersionID,
           let current = try await repository.pluginVersion(id: currentID),
           current.contentHash == hash.rawValue {
            try await saveDraft(draft, stage: "promoted", pluginID: draft.pluginID, repository: repository)
            let test = await runPromoteTest(
                pluginID: draft.pluginID,
                repository: repository,
                stdinExecutor: stdinExecutor,
                logger: logger
            )
            return encode([
                "ok": true,
                "stage": "promoted",
                "plugin_id": draft.pluginID,
                "version": current.version,
                "content_hash": hash.rawValue,
                "note": "Same content already installed.",
                "test": [
                    "heading": test.heading,
                    "body": test.body,
                    "kind": test.kind.rawValue,
                ],
            ])
        }

        let existingVersions = try await repository.listPluginVersions(pluginID: draft.pluginID)
        let reusedID = existingVersions.first(where: { $0.version == draft.version })?.id
        let version = PluginVersionRow(
            id: reusedID ?? UUID().uuidString,
            pluginID: draft.pluginID,
            version: draft.version,
            contentHash: hash.rawValue,
            status: "promoted",
            manifestJSON: manifest,
            runtimeJSON: runtime,
            dependenciesJSON: depsJSON,
            entrypointSource: draft.handle
        )
        try await repository.installPromotedPluginVersion(
            version,
            pluginID: draft.pluginID,
            grant: PluginGrantRow(
                pluginID: draft.pluginID,
                versionID: version.id,
                notifySessionID: MCPServiceCallContext.shared.memorySessionKey?.sessionID,
                dependenciesJSON: depsJSON
            )
        )
        try await saveDraft(draft, stage: "promoted", pluginID: draft.pluginID, repository: repository)
        let test = await runPromoteTest(
            pluginID: draft.pluginID,
            repository: repository,
            stdinExecutor: stdinExecutor,
            logger: logger
        )
        return encode([
            "ok": true,
            "stage": "promoted",
            "plugin_id": draft.pluginID,
            "version": draft.version,
            "content_hash": hash.rawValue,
            "test": [
                "heading": test.heading,
                "body": test.body,
                "kind": test.kind.rawValue,
            ],
        ])
    }

    private static func runPromoteTest(
        pluginID: String,
        repository: DBRepository,
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        logger: @escaping @Sendable (String) -> Void
    ) async -> PluginInvokePresentation.TestReport {
        do {
            let raw = try await invoke(
                args: [
                    "plugin_id": .string(pluginID),
                    "kind": .string(PluginEventKind.manual.rawValue),
                ],
                repository: repository,
                stdinExecutor: stdinExecutor,
                logger: logger
            )
            return PluginInvokePresentation.testReport(pluginID: pluginID, scriptResult: raw)
        } catch {
            return PluginInvokePresentation.TestReport(
                heading: "Testing new plugin \(pluginID)…",
                body: error.localizedDescription,
                kind: .programmatic
            )
        }
    }

    private static func installSample(
        repository: DBRepository,
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await requireFactorySession(repository)
        var draft = DailyNewsSample.draft()
        let findings = ScriptJSVerifier.validate(script: draft.handle, dependencies: draft.dependencies)
        if !findings.isEmpty {
            return encode(["ok": false, "static_findings": findings])
        }
        let volume = try await writeStagingVolume(draft: draft, exec: stdinExecutor)
        draft.workspaceVolume = volume
        draft.reviewPassed = true
        draft.reviewSummary = "Shipped sample; static checks passed."
        let result = try await ScriptExecutionRuntime.run(
            arguments: harnessArguments(draft: draft),
            stdinExecutor: stdinExecutor,
            reviewer: nil,
            logger: logger,
            reviewRequired: false,
            initialEvent: PluginHopEvent(kind: .harness, params: ["sample": .bool(true)])
        )
        draft.harnessPassed = harnessSucceeded(result)
        draft.lastHarnessSummary = draft.harnessPassed ? "sample fixtures passed" : harnessError(result)
        try await saveDraft(draft, stage: draft.harnessPassed ? "harnessed" : "written", pluginID: draft.pluginID, repository: repository)
        guard draft.harnessPassed else {
            return encode([
                "ok": false,
                "error": draft.lastHarnessSummary ?? "Sample harness failed.",
            ])
        }
        return try await promote(
            repository: repository,
            stdinExecutor: stdinExecutor,
            logger: logger
        )
    }

    private static func listPlugins(repository: DBRepository) async throws -> String {
        let plugins = try await repository.listPlugins(includeDisabled: true)
        var rows: [[String: Any]] = []
        for plugin in plugins {
            var version = ""
            var description = ""
            var hash = ""
            if let id = plugin.currentVersionID, let ver = try await repository.pluginVersion(id: id) {
                version = ver.version
                hash = ver.contentHash
                if let data = ver.manifestJSON.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    description = obj["description"] as? String ?? ""
                }
            }
            rows.append([
                "plugin_id": plugin.id,
                "enabled": plugin.enabled,
                "version": version,
                "description": description,
                "content_hash": hash,
            ])
        }
        return encode(["ok": true, "plugins": rows])
    }

    private static func invoke(
        args: [String: Value],
        repository: DBRepository,
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let pluginID = args["plugin_id"]?.stringValue ?? ""
        guard !pluginID.isEmpty else {
            return encode(["ok": false, "error": "plugin_id is required."])
        }
        guard let plugin = try await repository.plugin(id: pluginID), plugin.enabled else {
            return encode(["ok": false, "error": "Plugin \(pluginID) is not installed or is disabled."])
        }
        guard let versionID = plugin.currentVersionID,
              let version = try await repository.pluginVersion(id: versionID) else {
            return encode(["ok": false, "error": "Plugin \(pluginID) has no promoted version."])
        }
        guard !version.entrypointSource.isEmpty else {
            return encode(["ok": false, "error": "Plugin \(pluginID) has no stored handle."])
        }
        MCPServiceCallContext.shared.setPluginID(pluginID)
        defer { MCPServiceCallContext.shared.setPluginID(nil) }

        var deps: [String: String] = [:]
        if let data = version.dependenciesJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            deps = obj
        }

        let files: [String: Data] = [
            "plugin.json": Data(version.manifestJSON.utf8),
            "app.derrick/runtime.json": Data((version.runtimeJSON ?? "{}").utf8),
            "app.derrick/plugin.ts": Data(version.entrypointSource.utf8),
        ]
        let recomputed = PluginContentHash.hash(files: files)
        if recomputed.rawValue != version.contentHash {
            try await repository.setPluginEnabled(id: pluginID, enabled: false)
            return encode([
                "ok": false,
                "error": "content_hash mismatch; plugin disabled.",
                "expected": version.contentHash,
                "actual": recomputed.rawValue,
            ])
        }

        var scriptArgs: [String: Value] = [
            "description": .string(pluginID),
            "reason": .string("plugin.invoke \(pluginID)"),
            "script": .string(version.entrypointSource),
        ]
        if !deps.isEmpty {
            scriptArgs["dependencies"] = .object(deps.mapValues { .string($0) })
        }
        let kind = PluginEventKind(rawValue: args["kind"]?.stringValue ?? "") ?? .manual
        let params: [String: PluginJSON]
        do {
            params = try invokeParams(from: args["params"])
        } catch {
            return encode(["ok": false, "error": error.localizedDescription])
        }
        let result = try await ScriptExecutionRuntime.run(
            arguments: scriptArgs,
            stdinExecutor: stdinExecutor,
            reviewer: nil,
            logger: logger,
            reviewRequired: false,
            initialEvent: PluginHopEvent(kind: kind, params: params.isEmpty ? nil : params),
            hopHandler: FactoryPluginHopHandler(pluginID: pluginID, repository: repository)
        )
        let invokeID = UUID().uuidString
        let principal = (try? JSONEncoder.service.encode(
            ServicePrincipal.plugin(pluginID: pluginID, version: version.version)
        )).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try await repository.upsertPluginInvoke(
            PluginInvokeRow(
                pluginID: pluginID,
                versionID: version.id,
                invokeID: invokeID,
                kind: args["kind"]?.stringValue ?? "manual",
                status: "succeeded",
                principalJSON: principal,
                resultJSON: result
            )
        )
        return result
    }

    // MARK: - Session

    private static func factorySessionID() throws -> String {
        let chat = MCPServiceCallContext.shared.memorySessionKey?.sessionID ?? ""
        guard FactorySessionID.isFactorySession(chat) else {
            throw NSError(
                domain: "PluginFactory",
                code: 403,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Factory tools only run in a Software Factory session. Open one from the sidebar.",
                ]
            )
        }
        return chat
    }

    private static func loadSession(_ repository: DBRepository) async throws -> FactorySessionRow {
        let id = try factorySessionID()
        if let existing = try await repository.factorySession(sessionID: id) {
            return existing
        }
        let row = FactorySessionRow(sessionID: id, stage: "spec")
        try await repository.upsertFactorySession(row)
        return row
    }

    private static func loadDraft(_ repository: DBRepository) async throws -> FactoryPackageDraft {
        let session = try await loadSession(repository)
        guard let raw = session.specJSON, let data = raw.data(using: .utf8),
              let draft = try? JSONDecoder().decode(FactoryPackageDraft.self, from: data) else {
            return FactoryPackageDraft(goal: "")
        }
        return draft
    }

    private static func saveDraft(
        _ draft: FactoryPackageDraft,
        stage: String,
        pluginID: String? = nil,
        repository: DBRepository
    ) async throws {
        var session = try await loadSession(repository)
        let data = try JSONEncoder().encode(draft)
        session.specJSON = String(decoding: data, as: UTF8.self)
        session.stage = stage
        if let pluginID { session.pluginID = pluginID }
        session.updatedAt = .now
        try await repository.upsertFactorySession(session)
    }

    private static func invokeParams(from value: Value?) throws -> [String: PluginJSON] {
        guard let value else { return [:] }
        guard case .object(let object) = value else {
            throw NSError(
                domain: "PluginFactory",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "params must be a JSON object."]
            )
        }
        var params: [String: PluginJSON] = [:]
        for (key, item) in object {
            params[key] = pluginJSON(from: item)
        }
        let encoded = try JSONEncoder().encode(params)
        guard encoded.count <= PluginContract.maxInvokeParamsBytes else {
            throw NSError(
                domain: "PluginFactory",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "params exceed \(PluginContract.maxInvokeParamsBytes) bytes."]
            )
        }
        return params
    }

    private static func pluginJSON(from value: Value) -> PluginJSON {
        switch value {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .int(let number): return .number(Double(number))
        case .double(let number): return .number(number)
        case .string(let text): return .string(text)
        case .array(let items): return .array(items.map(pluginJSON(from:)))
        case .object(let object):
            return .object(object.mapValues(pluginJSON(from:)))
        default:
            return .string(String(describing: value))
        }
    }

    private static func requireFactorySession(_ repository: DBRepository) async throws {
        guard await isFactoryEnabled(repository) else {
            throw NSError(
                domain: "PluginFactory",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Software Factory is off. Enable it in Settings."]
            )
        }
        _ = try factorySessionID()
    }

    private static func writeStagingVolume(
        draft: FactoryPackageDraft,
        exec: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult
    ) async throws -> String {
        let sessionID = try factorySessionID()
        let volume = DerrickNamedVolume.pluginStaging(factoryID: sessionID)
        try await DockerVolumeIO.ensureVolume(name: volume, exec: exec)
        for (path, data) in try draft.stagingFiles() where !data.isEmpty {
            try await DockerVolumeIO.writeFile(
                volume: volume,
                relativePath: path,
                data: data,
                exec: exec
            )
        }
        return volume
    }

    private static func loadFactoryCaps(_ repository: DBRepository) async -> (maxReviewer: Int, maxHarness: Int) {
        guard let raw = try? await repository.loadConfig(
            key: "usageLimits.v1",
            username: "ui",
            password: "ui"
        ),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FactoryUsageCapsDTO.self, from: data) else {
            return (6, 6)
        }
        return (
            decoded.maxFactoryReviewerCallsPerBuild ?? 6,
            decoded.maxHarnessRunsPerBuild ?? 6
        )
    }

    private static func harnessArguments(draft: FactoryPackageDraft) -> [String: Value] {
        var args: [String: Value] = [
            "description": .string(draft.description),
            "reason": .string("Factory harness for \(draft.pluginID)"),
            "script": .string(draft.handle),
        ]
        if !draft.dependencies.isEmpty {
            args["dependencies"] = .object(draft.dependencies.mapValues { .string($0) })
        }
        return args
    }

    private static func harnessSucceeded(_ resultJSON: String) -> Bool {
        guard let data = resultJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let ok = obj["ok"] as? Bool { return ok }
        if let status = obj["status"] as? String {
            return status == "completed" || status == "succeeded" || status == "ok"
        }
        if let exitCode = obj["exit_code"] as? Int {
            return exitCode == 0
        }
        return !resultJSON.lowercased().contains("\"status\":\"failed\"")
    }

    private static func harnessError(_ resultJSON: String) -> String {
        guard let data = resultJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(resultJSON.prefix(240))
        }
        if let findings = obj["validation_findings"] as? [String], let first = findings.first {
            return first
        }
        if let error = obj["error"] as? String { return error }
        if let stderr = obj["stderr"] as? String, !stderr.isEmpty { return String(stderr.prefix(240)) }
        return "Harness failed."
    }

    private static func objectSchema(_ properties: [String: Value], required: [String] = []) -> Value {
        var object: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            object["required"] = .array(required.map { .string($0) })
        }
        return .object(object)
    }

    private static func stringProp(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct FactoryUsageCapsDTO: Decodable {
    var maxFactoryReviewerCallsPerBuild: Int?
    var maxHarnessRunsPerBuild: Int?
}

private extension Value {
    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        default: return nil
        }
    }
}
