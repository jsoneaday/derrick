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
            try await build(args: args, repository: repository, logger: logger)
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
                "fixtures": stringProp(
                    "Optional JSON array of sample test runs, e.g. [{\"kind\":\"test\",\"params\":{\"topic\":\"technology\",\"max\":5}}]. Used for factory.test and the live check after install."
                ),
                "params_schema": stringProp(
                    "Optional JSON object of param name → type (string, number, boolean, string[]). Host uses this for the post-promote test."
                ),
            ], required: ["plugin_id", "description", "handle"])
        ) { args in
            try await writePackage(
                args: args,
                repository: repository,
                stdinExecutor: stdinExecutor,
                logger: logger
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
            tool: .factoryTest,
            description: AllowedMCPTool.factoryTest.defaultDescription,
            inputSchema: objectSchema([
                "fixtures": .object([
                    "type": .string("string"),
                    "description": .string("Optional JSON array of sample test runs. Default uses the package samples."),
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
                 AllowedMCPTool.factoryTest.rawValue,
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

    private static func build(
        args: [String: Value],
        repository: DBRepository,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> String {
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
        let installed = try await installedPluginSummaries(repository)
        let installedIDs = installed.compactMap { $0["id"] }
        let locked = draft.reusePluginID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !locked.isEmpty, installedIDs.contains(locked) {
            draft.pluginID = locked
            draft.reusePluginID = locked
        } else {
            switch FactoryExistingPlugin.decide(goal: goal, installedIDs: installedIDs) {
            case .reuse(let id):
                draft.pluginID = id
                draft.reusePluginID = id
            case .create:
                draft.reusePluginID = nil
            case .ambiguous(let ids):
                let listed = ids.joined(separator: ", ")
                let encoded = encode([
                    "ok": false,
                    "ask_user": true,
                    "candidates": ids,
                    "installed_plugins": installed,
                    "error": "More than one plugin matches. Ask the user which they mean: \(listed). Then call factory.build again with that plugin named in the goal.",
                ])
                record(logger, draft: &draft, tool: "factory.build", arguments: ["goal": goal], result: encoded)
                try await saveDraft(draft, stage: "spec", repository: repository)
                return encoded
            }
        }
        var payload: [String: Any] = [
            "ok": true,
            "factory_session_id": try factorySessionID(),
            "stage": "spec",
            "goal": draft.goal,
            "installed_plugins": installed,
            "next": "factory.write_package",
        ]
        if let reuse = draft.reusePluginID {
            payload["reuse_plugin_id"] = reuse
            payload["next"] = "factory.write_package plugin_id=\(reuse)"
        }
        let encoded = encode(payload)
        record(logger, draft: &draft, tool: "factory.build", arguments: ["plugin_id": draft.pluginID], result: encoded)
        try await saveDraft(draft, stage: "spec", repository: repository)
        var session = try await loadSession(repository)
        session.reviewerCalls = 0
        session.harnessRuns = 0
        session.updatedAt = .now
        try await repository.upsertFactorySession(session)
        return encoded
    }

    private static func writePackage(
        args: [String: Value],
        repository: DBRepository,
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await requireFactorySession(repository)
        var draft = try await loadDraft(repository)
        let pluginID = args["plugin_id"]?.stringValue ?? ""
        let description = args["description"]?.stringValue ?? ""
        let handle = args["handle"]?.stringValue ?? ""
        let resolvedFromReuse = draft.reusePluginID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedID = resolvedFromReuse.isEmpty ? pluginID : resolvedFromReuse
        guard !resolvedID.isEmpty, !description.isEmpty, !handle.isEmpty else {
            return encode(["ok": false, "error": "plugin_id, description, and handle are required."])
        }
        _ = try PluginID(resolvedID)
        var deps: [String: String] = [:]
        if let obj = args["dependencies"]?.objectValue {
            for (key, value) in obj {
                if let spec = value.stringValue { deps[key] = spec }
            }
        }
        draft.pluginID = resolvedID
        let requestedVersion = args["version"]?.stringValue?.isEmpty == false
            ? (args["version"]?.stringValue ?? "1.0.0")
            : "1.0.0"
        let existingVersions = try await repository.listPluginVersions(pluginID: resolvedID)
        draft.version = PluginReleaseVersion.assign(
            requested: requestedVersion,
            existing: existingVersions.map(\.version)
        )
        draft.description = description
        draft.handle = handle
        draft.dependencies = deps
        draft.volumeEnabled = args["volume_enabled"]?.boolValue ?? false
        if let schema = args["params_schema"]?.stringValue,
           !schema.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.paramsSchemaJSON = schema
        }
        if let fixtures = args["fixtures"]?.stringValue,
           !fixtures.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !FactoryInvokeParams.isPlaceholder(FactoryInvokeParams.parseFixtureParams(fixtures).first ?? [:]) {
            draft.fixturesJSON = fixtures
        } else {
            draft.fixturesJSON = FactoryPackageDraft.defaultFixturesJSON
        }
        draft.reviewPassed = false
        draft.reviewSummary = nil
        draft.harnessPassed = false
        draft.lastHarnessSummary = nil

        _ = try draft.pluginJSON()
        _ = try draft.runtimeJSON()
        var findings = ScriptJSVerifier.validate(script: handle, dependencies: deps)
        findings.append(contentsOf: PluginParamsContract.validate(handle))
        if !findings.isEmpty {
            let encoded = encode([
                "ok": false,
                "stage": "written",
                "static_findings": findings,
                "next": "Fix static_findings and call factory.write_package again.",
            ])
            record(
                logger,
                draft: &draft,
                tool: "factory.write_package",
                arguments: ["plugin_id": resolvedID, "handle": handle],
                result: encoded
            )
            try await saveDraft(draft, stage: "written", repository: repository)
            return encoded
        }
        let volume = try await writeStagingVolume(draft: draft, exec: stdinExecutor)
        draft.workspaceVolume = volume
        let encoded = encode([
            "ok": true,
            "stage": "written",
            "plugin_id": resolvedID,
            "version": draft.version,
            "workspace_volume": volume,
            "hash": try draft.contentHash().rawValue,
            "next": "factory.review",
        ])
        record(
            logger,
            draft: &draft,
            tool: "factory.write_package",
            arguments: ["plugin_id": resolvedID, "handle": handle],
            result: encoded
        )
        try await saveDraft(draft, stage: "written", pluginID: resolvedID, repository: repository)
        return encoded
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
        let encoded = encode([
            "ok": passed,
            "stage": passed ? "reviewed" : "written",
            "summary": outcome.assessment.summary,
            "concerns": outcome.assessment.concerns,
            "next": passed ? "factory.test" : "factory.write_package",
        ])
        record(
            logger,
            draft: &draft,
            tool: "factory.review",
            arguments: ["plugin_id": draft.pluginID, "handle": draft.handle],
            result: encoded
        )
        try await saveDraft(draft, stage: passed ? "reviewed" : "written", repository: repository)
        return encoded
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
                "error": "Factory test limit reached (\(caps.maxHarness) per build). Raise it in Settings → Usage limits.",
            ])
        }
        session.harnessRuns += 1
        session.updatedAt = .now
        try await repository.upsertFactorySession(session)

        if let fixtures = args["fixtures"]?.stringValue, !fixtures.isEmpty {
            draft.fixturesJSON = fixtures
        }
        var findings = ScriptJSVerifier.validate(script: draft.handle, dependencies: draft.dependencies)
        findings.append(contentsOf: PluginParamsContract.validate(draft.handle))
        if !findings.isEmpty {
            draft.harnessPassed = false
            draft.lastHarnessSummary = findings.joined(separator: "; ")
            let encoded = encode(["ok": false, "stage": "written", "static_findings": findings])
            record(
                logger,
                draft: &draft,
                tool: "factory.test",
                arguments: ["plugin_id": draft.pluginID, "handle": draft.handle],
                result: encoded
            )
            try await saveDraft(draft, stage: "written", repository: repository)
            return encoded
        }

        let result = try await ScriptExecutionRuntime.run(
            arguments: harnessArguments(draft: draft),
            stdinExecutor: stdinExecutor,
            reviewer: nil,
            logger: logger,
            reviewRequired: false,
            initialEvent: PluginHopEvent(kind: .harness, params: harnessParams(for: draft))
        )
        let ok = pluginTestPassed(result)
        draft.harnessPassed = ok
        draft.lastHarnessSummary = ok ? "Tests passed." : pluginTestError(result)
        let encoded = encode([
            "ok": ok,
            "stage": ok ? "tested" : "written",
            "summary": draft.lastHarnessSummary ?? "",
            "stdout": testStdout(result),
            "next": ok ? "factory.promote" : "factory.write_package",
        ])
        record(
            logger,
            draft: &draft,
            tool: "factory.test",
            arguments: ["plugin_id": draft.pluginID, "handle": draft.handle],
            result: encoded
        )
        try await saveDraft(draft, stage: ok ? "tested" : "written", repository: repository)
        return encoded
    }

    private static func promote(
        repository: DBRepository,
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        logger: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await requireFactorySession(repository)
        var draft = try await loadDraft(repository)
        guard draft.reviewPassed else {
            return encode(["ok": false, "error": "factory.review must pass before promote."])
        }
        guard draft.harnessPassed else {
            return encode(["ok": false, "error": "factory.test must pass before install."])
        }
        guard !draft.pluginID.isEmpty, !draft.handle.isEmpty else {
            return encode(["ok": false, "error": "No package to promote."])
        }

        let existingPlugin = try await repository.plugin(id: draft.pluginID)
        let existingVersions = try await repository.listPluginVersions(pluginID: draft.pluginID)
        let isUpdate = existingPlugin != nil
        if isUpdate {
            draft.version = PluginReleaseVersion.assign(
                requested: draft.version,
                existing: existingVersions.map(\.version)
            )
        }

        let event = PolicyUserEventFactory.pluginInstall(
            pluginID: draft.pluginID,
            version: draft.version,
            summary: isUpdate
                ? "Update \(draft.pluginID) to \(draft.version)? \(draft.description)"
                : "Install \(draft.pluginID) \(draft.version)? \(draft.description)",
            detail: draft.installSummary(),
            payloadPreview: draft.handle,
            toolName: AllowedMCPTool.factoryPromote.rawValue,
            isUpdate: isUpdate
        )
        let decision = await PolicyDecisionRouting.requestDecision(event)
        switch decision {
        case .approved, .approvedOnce, .approvedPermanently:
            break
        case .timedOut:
            let encoded = encode([
                "ok": false,
                "error": "Install approval timed out. Call factory.promote again.",
            ])
            record(logger, draft: &draft, tool: "factory.promote", arguments: ["plugin_id": draft.pluginID], result: encoded)
            try await saveDraft(draft, stage: "written", repository: repository)
            return encoded
        case .denied, .dismissed:
            let encoded = encode(["ok": false, "error": "User declined the install."])
            record(logger, draft: &draft, tool: "factory.promote", arguments: ["plugin_id": draft.pluginID], result: encoded)
            try await saveDraft(draft, stage: "written", repository: repository)
            return encoded
        }

        let runtime = try draft.runtimeJSON()
        let depsData = try JSONSerialization.data(withJSONObject: draft.dependencies)
        let depsJSON = String(decoding: depsData, as: UTF8.self)

        if let currentID = try await repository.plugin(id: draft.pluginID)?.currentVersionID,
           let current = try await repository.pluginVersion(id: currentID),
           current.entrypointSource == draft.handle,
           current.runtimeJSON == runtime,
           current.dependenciesJSON == depsJSON {
            try await saveDraft(draft, stage: "promoted", pluginID: draft.pluginID, repository: repository)
            let test = await runPromoteTest(
                draft: draft,
                repository: repository,
                stdinExecutor: stdinExecutor,
                logger: logger
            )
            return encodePromoted(
                pluginID: draft.pluginID,
                version: current.version,
                contentHash: current.contentHash,
                test: test,
                note: "Same content already installed."
            )
        }

        let hash = try draft.contentHash()
        let manifest = try draft.pluginJSON()
        let version = PluginVersionRow(
            id: UUID().uuidString,
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
            draft: draft,
            repository: repository,
            stdinExecutor: stdinExecutor,
            logger: logger
        )
        return encodePromoted(
            pluginID: draft.pluginID,
            version: draft.version,
            contentHash: hash.rawValue,
            test: test
        )
    }

    private static func encodePromoted(
        pluginID: String,
        version: String,
        contentHash: String,
        test: PluginInvokePresentation.TestReport,
        note: String? = nil
    ) -> String {
        DerrickPluginCatalogSignal.post()
        var payload: [String: Any] = [
            "ok": true,
            "stage": "promoted",
            "plugin_id": pluginID,
            "version": version,
            "content_hash": contentHash,
            "test": [
                "heading": test.heading,
                "body": test.body,
                "kind": test.kind.rawValue,
            ],
        ]
        if let note { payload["note"] = note }
        return encode(payload)
    }

    private static func runPromoteTest(
        draft: FactoryPackageDraft,
        repository: DBRepository,
        stdinExecutor: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult,
        logger: @escaping @Sendable (String) -> Void
    ) async -> PluginInvokePresentation.TestReport {
        let params = FactoryInvokeParams.resolve(
            fixturesJSON: draft.fixturesJSON,
            handle: draft.handle,
            goal: draft.goal,
            schemaJSON: draft.paramsSchemaJSON
        )
        let heading = FactoryInvokeParams.testHeading(pluginID: draft.pluginID, params: params)
        do {
            var args: [String: Value] = [
                "plugin_id": .string(draft.pluginID),
                "kind": .string(PluginEventKind.manual.rawValue),
            ]
            if !params.isEmpty {
                args["params"] = mcpValue(from: .object(params))
            }
            let raw = try await invoke(
                args: args,
                repository: repository,
                stdinExecutor: stdinExecutor,
                logger: logger
            )
            var report = PluginInvokePresentation.testReport(pluginID: draft.pluginID, scriptResult: raw)
            report.heading = heading
            return report
        } catch {
            return PluginInvokePresentation.TestReport(
                heading: heading,
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
        var findings = ScriptJSVerifier.validate(script: draft.handle, dependencies: draft.dependencies)
        findings.append(contentsOf: PluginParamsContract.validate(draft.handle))
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
            initialEvent: PluginHopEvent(kind: .harness, params: harnessParams(for: draft))
        )
        draft.harnessPassed = pluginTestPassed(result)
        draft.lastHarnessSummary = draft.harnessPassed ? "Sample tests passed." : pluginTestError(result)
        try await saveDraft(draft, stage: draft.harnessPassed ? "tested" : "written", pluginID: draft.pluginID, repository: repository)
        guard draft.harnessPassed else {
            return encode([
                "ok": false,
                "error": draft.lastHarnessSummary ?? "Sample test failed.",
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

    private static func installedPluginSummaries(_ repository: DBRepository) async throws -> [[String: String]] {
        let plugins = try await repository.listPlugins(includeDisabled: true)
        var rows: [[String: String]] = []
        for plugin in plugins {
            var version = ""
            if let id = plugin.currentVersionID, let ver = try await repository.pluginVersion(id: id) {
                version = ver.version
            }
            rows.append(["id": plugin.id, "version": version])
        }
        return rows
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
        var draft: FactoryPackageDraft
        if let raw = session.specJSON, let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(FactoryPackageDraft.self, from: data) {
            draft = decoded
        } else {
            draft = FactoryPackageDraft(goal: "")
        }
        let locked = session.pluginID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !locked.isEmpty {
            if draft.reusePluginID?.isEmpty != false {
                draft.reusePluginID = locked
            }
            if draft.pluginID.isEmpty {
                draft.pluginID = locked
            }
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
        if let pluginID {
            session.pluginID = pluginID
        } else if let reuse = draft.reusePluginID, !reuse.isEmpty {
            session.pluginID = reuse
        } else if !draft.pluginID.isEmpty {
            session.pluginID = draft.pluginID
        }
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

    private static func mcpValue(from json: PluginJSON) -> Value {
        switch json {
        case .null:
            return .null
        case .bool(let flag):
            return .bool(flag)
        case .number(let number):
            if number.rounded() == number,
               number >= Double(Int.min),
               number <= Double(Int.max) {
                return .int(Int(number))
            }
            return .double(number)
        case .string(let text):
            return .string(text)
        case .array(let items):
            return .array(items.map(mcpValue(from:)))
        case .object(let object):
            return .object(object.mapValues { mcpValue(from: $0) })
        }
    }

    private static func harnessParams(for draft: FactoryPackageDraft) -> [String: PluginJSON] {
        let resolved = FactoryInvokeParams.resolve(
            fixturesJSON: draft.fixturesJSON,
            handle: draft.handle,
            goal: draft.goal,
            schemaJSON: draft.paramsSchemaJSON
        )
        return resolved.isEmpty ? [FactoryInvokeParams.placeholderKey: .bool(true)] : resolved
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
            return (12, 12)
        }
        return (
            decoded.maxFactoryReviewerCallsPerBuild ?? 12,
            decoded.maxHarnessRunsPerBuild ?? 12
        )
    }

    private static func harnessArguments(draft: FactoryPackageDraft) -> [String: Value] {
        var args: [String: Value] = [
            "description": .string(draft.description),
            "reason": .string("Factory test for \(draft.pluginID)"),
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

    private static func pluginTestPassed(_ resultJSON: String) -> Bool {
        guard harnessSucceeded(resultJSON) else { return false }
        let report = PluginInvokePresentation.testReport(pluginID: "plugin", scriptResult: resultJSON)
        return !PluginInvokePresentation.isEmptyResult(report.body)
    }

    private static func pluginTestError(_ resultJSON: String) -> String {
        let report = PluginInvokePresentation.testReport(pluginID: "plugin", scriptResult: resultJSON)
        if PluginInvokePresentation.isEmptyResult(report.body) {
            return report.body.isEmpty
                ? "The plugin test returned no usable output. handle() must still produce useful output when params are omitted."
                : report.body
        }
        guard let data = resultJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(resultJSON.prefix(240))
        }
        if let findings = obj["validation_findings"] as? [String], let first = findings.first {
            return first
        }
        if let error = obj["error"] as? String { return error }
        if let stderr = obj["stderr"] as? String, !stderr.isEmpty { return String(stderr.prefix(240)) }
        return "Test failed."
    }

    private static func testStdout(_ resultJSON: String) -> String {
        let report = PluginInvokePresentation.testReport(pluginID: "plugin", scriptResult: resultJSON)
        if !report.body.isEmpty { return report.body }
        return String(resultJSON.prefix(400))
    }

    private static func record(
        _ logger: @escaping @Sendable (String) -> Void,
        draft: inout FactoryPackageDraft,
        tool: String,
        arguments: [String: String],
        result: String
    ) {
        let line = FactoryAttemptLog.describe(tool: tool, arguments: arguments, result: result)
        draft.recordAttempt(line)
        logger(line)
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
