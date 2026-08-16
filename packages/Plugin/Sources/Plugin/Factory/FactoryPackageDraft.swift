import Foundation

/// In-progress factory package stored on `factory_sessions.spec_json`.
public struct FactoryPackageDraft: Codable, Sendable, Equatable {
    public var goal: String
    public var pluginID: String
    public var version: String
    public var description: String
    public var handle: String
    public var dependencies: [String: String]
    public var volumeEnabled: Bool
    public var reviewPassed: Bool
    public var reviewSummary: String?
    /// Named Docker volume holding the package files (`derrick-plugin-staging-…`).
    public var workspaceVolume: String?
    /// JSON array of sample test runs: `[{ "kind": "test", "params": {…} }]`.
    public var fixturesJSON: String
    public var harnessPassed: Bool
    public var lastHarnessSummary: String?
    /// When set, write/promote must keep this installed id and add a version.
    public var reusePluginID: String?
    /// Optional `{"max":"number","topics":"string[]"}` used for factory.test and the install check.
    public var paramsSchemaJSON: String
    /// Host-recorded write/review/test/promote attempts for this session.
    public var attemptLog: [String]

    public init(
        goal: String = "",
        pluginID: String = "",
        version: String = "1.0.0",
        description: String = "",
        handle: String = "",
        dependencies: [String: String] = [:],
        volumeEnabled: Bool = false,
        reviewPassed: Bool = false,
        reviewSummary: String? = nil,
        workspaceVolume: String? = nil,
        fixturesJSON: String = FactoryPackageDraft.defaultFixturesJSON,
        harnessPassed: Bool = false,
        lastHarnessSummary: String? = nil,
        reusePluginID: String? = nil,
        paramsSchemaJSON: String = "",
        attemptLog: [String] = []
    ) {
        self.goal = goal
        self.pluginID = pluginID
        self.version = version
        self.description = description
        self.handle = handle
        self.dependencies = dependencies
        self.volumeEnabled = volumeEnabled
        self.reviewPassed = reviewPassed
        self.reviewSummary = reviewSummary
        self.workspaceVolume = workspaceVolume
        self.fixturesJSON = fixturesJSON.isEmpty ? Self.defaultFixturesJSON : fixturesJSON
        self.harnessPassed = harnessPassed
        self.lastHarnessSummary = lastHarnessSummary
        self.reusePluginID = reusePluginID
        self.paramsSchemaJSON = paramsSchemaJSON
        self.attemptLog = attemptLog
    }

    public static let defaultFixturesJSON = #"[{"kind":"test","params":{"sample":true}}]"#

    enum CodingKeys: String, CodingKey {
        case goal, pluginID, version, description, handle, dependencies
        case volumeEnabled, reviewPassed, reviewSummary
        case workspaceVolume, fixturesJSON, harnessPassed, lastHarnessSummary, reusePluginID
        case paramsSchemaJSON, attemptLog
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goal = try container.decodeIfPresent(String.self, forKey: .goal) ?? ""
        pluginID = try container.decodeIfPresent(String.self, forKey: .pluginID) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        handle = try container.decodeIfPresent(String.self, forKey: .handle) ?? ""
        dependencies = try container.decodeIfPresent([String: String].self, forKey: .dependencies) ?? [:]
        volumeEnabled = try container.decodeIfPresent(Bool.self, forKey: .volumeEnabled) ?? false
        reviewPassed = try container.decodeIfPresent(Bool.self, forKey: .reviewPassed) ?? false
        reviewSummary = try container.decodeIfPresent(String.self, forKey: .reviewSummary)
        workspaceVolume = try container.decodeIfPresent(String.self, forKey: .workspaceVolume)
        let fixtures = try container.decodeIfPresent(String.self, forKey: .fixturesJSON) ?? ""
        fixturesJSON = fixtures.isEmpty ? Self.defaultFixturesJSON : fixtures
        harnessPassed = try container.decodeIfPresent(Bool.self, forKey: .harnessPassed) ?? false
        lastHarnessSummary = try container.decodeIfPresent(String.self, forKey: .lastHarnessSummary)
        reusePluginID = try container.decodeIfPresent(String.self, forKey: .reusePluginID)
        paramsSchemaJSON = try container.decodeIfPresent(String.self, forKey: .paramsSchemaJSON) ?? ""
        attemptLog = try container.decodeIfPresent([String].self, forKey: .attemptLog) ?? []
    }

    public mutating func recordAttempt(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        attemptLog.append(trimmed)
        if attemptLog.count > 40 {
            attemptLog.removeFirst(attemptLog.count - 40)
        }
    }

    public func pluginJSON() throws -> String {
        let id = try PluginID(pluginID)
        let object: [String: Any] = [
            "$schema": PluginContract.agentPluginSchema,
            "name": id.rawValue,
            "version": version,
            "description": description,
            "extensions": [
                PluginContract.derrickExtensionNamespace: [
                    "runtime": "./app.derrick/runtime.json",
                    "entrypoint": "./app.derrick/plugin.ts",
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public func runtimeJSON() throws -> String {
        let runtime = try DerrickRuntime(
            entrypoint: "plugin.ts",
            dependencies: dependencies,
            volume: DerrickRuntimeVolume(enabled: volumeEnabled)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(runtime)
        return String(decoding: data, as: UTF8.self)
    }

    public func hashableFiles() throws -> [String: Data] {
        [
            "plugin.json": Data(try pluginJSON().utf8),
            "app.derrick/runtime.json": Data(try runtimeJSON().utf8),
            "app.derrick/plugin.ts": Data(handle.utf8),
        ]
    }

    public func stagingFiles() throws -> [String: Data] {
        var files = try hashableFiles()
        if !fixturesJSON.isEmpty {
            files["app.derrick/fixtures.json"] = Data(fixturesJSON.utf8)
        }
        return files
    }

    public func contentHash() throws -> PluginContentHash {
        try PluginContentHash.hash(files: hashableFiles())
    }

    public func installSummary() -> String {
        var lines: [String] = [
            "\(pluginID) \(version)",
            description,
        ]
        if !dependencies.isEmpty {
            let deps = dependencies.keys.sorted().joined(separator: ", ")
            lines.append("Dependencies: \(deps)")
        } else {
            lines.append("Dependencies: none")
        }
        lines.append(
            volumeEnabled
                ? "Private /data volume: yes (uninstall deletes it)."
                : "Private /data volume: no."
        )
        if let hash = try? contentHash() {
            lines.append("Content hash: \(hash.rawValue)")
        }
        if let reviewSummary, !reviewSummary.isEmpty {
            lines.append("Review: \(reviewSummary)")
        }
        if let lastHarnessSummary, !lastHarnessSummary.isEmpty {
            lines.append("Test: \(lastHarnessSummary)")
        }
        return lines.joined(separator: "\n")
    }
}
