import Foundation

/// Derrick runtime metadata (`app.derrick/runtime.json`) for a standalone Swift entrypoint.
public struct DerrickRuntime: Codable, Sendable, Hashable {
    public var entrypoint: String
    public var dependencies: [String: String]
    public var triggers: [PluginTrigger]
    public var authRefs: [PluginAuthRef]
    public var ui: DerrickRuntimeUI
    public var jobs: DerrickRuntimeJobs
    public var volume: DerrickRuntimeVolume
    public var quotas: DerrickRuntimeQuotas

    public init(
        entrypoint: String,
        dependencies: [String: String] = [:],
        triggers: [PluginTrigger] = [],
        authRefs: [PluginAuthRef] = [],
        ui: DerrickRuntimeUI = DerrickRuntimeUI(),
        jobs: DerrickRuntimeJobs = DerrickRuntimeJobs(),
        volume: DerrickRuntimeVolume = DerrickRuntimeVolume(),
        quotas: DerrickRuntimeQuotas = DerrickRuntimeQuotas()
    ) throws {
        self.entrypoint = try DerrickRuntime.normalizeEntrypoint(entrypoint)
        self.dependencies = try DerrickRuntime.validateDependencies(dependencies)
        self.triggers = try triggers.map { try $0.validated() }
        self.authRefs = authRefs
        self.ui = ui
        self.jobs = jobs
        self.volume = volume
        self.quotas = quotas
    }

    enum CodingKeys: String, CodingKey {
        case entrypoint, dependencies, triggers
        case authRefs = "auth_refs"
        case ui, jobs, volume, quotas
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entrypoint = try container.decode(String.self, forKey: .entrypoint)
        let dependencies = try container.decodeIfPresent([String: String].self, forKey: .dependencies) ?? [:]
        let triggers = try container.decodeIfPresent([PluginTrigger].self, forKey: .triggers) ?? []
        let authRefs = try container.decodeIfPresent([PluginAuthRef].self, forKey: .authRefs) ?? []
        let ui = try container.decodeIfPresent(DerrickRuntimeUI.self, forKey: .ui) ?? DerrickRuntimeUI()
        let jobs = try container.decodeIfPresent(DerrickRuntimeJobs.self, forKey: .jobs) ?? DerrickRuntimeJobs()
        let volume = try container.decodeIfPresent(DerrickRuntimeVolume.self, forKey: .volume) ?? DerrickRuntimeVolume()
        let quotas = try container.decodeIfPresent(DerrickRuntimeQuotas.self, forKey: .quotas) ?? DerrickRuntimeQuotas()
        try self.init(
            entrypoint: entrypoint,
            dependencies: dependencies,
            triggers: triggers,
            authRefs: authRefs,
            ui: ui,
            jobs: jobs,
            volume: volume,
            quotas: quotas
        )
    }

    /// Runtime `entrypoint` is plugin-relative or a bare supported source name
    /// resolved under `app.derrick/`.
    public static func normalizeEntrypoint(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("./") {
            return try PluginPath.validateRuntimeEntrypoint(trimmed)
        }
        guard trimmed.hasSuffix(".swift"),
              !trimmed.contains("/"),
              !trimmed.contains("\\") else {
            throw PluginManifestError.invalidEntrypoint(raw)
        }
        return try PluginPath.validateRuntimeEntrypoint("./\(PluginContract.derrickExtensionNamespace)/\(trimmed)")
    }

    public static func validateDependencies(_ deps: [String: String]) throws -> [String: String] {
        guard deps.isEmpty else {
            let name = deps.keys.sorted().joined(separator: ", ")
            throw PluginManifestError.invalidDependency(name)
        }
        return [:]
    }

    public var wantsDataVolume: Bool { volume.enabled }
}

public struct DerrickRuntimeUI: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var surfaces: [String]

    public init(schemaVersion: Int = PluginContract.uiSchemaVersion, surfaces: [String] = ["card"]) {
        self.schemaVersion = schemaVersion
        self.surfaces = surfaces
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case surfaces
    }
}

public struct DerrickRuntimeJobs: Codable, Sendable, Hashable {
    public var schedule: Bool

    public init(schedule: Bool = false) {
        self.schedule = schedule
    }
}

public struct DerrickRuntimeVolume: Codable, Sendable, Hashable {
    /// Opt-in persistent `/data` mount. Default off.
    public var enabled: Bool
    public var quotaBytes: Int

    public init(enabled: Bool = false, quotaBytes: Int = PluginContract.defaultVolumeQuotaBytes) {
        self.enabled = enabled
        self.quotaBytes = quotaBytes
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case quotaBytes = "quota_bytes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        quotaBytes = try container.decodeIfPresent(Int.self, forKey: .quotaBytes)
            ?? PluginContract.defaultVolumeQuotaBytes
    }
}

public struct DerrickRuntimeQuotas: Codable, Sendable, Hashable {
    public var timeoutSeconds: Int
    public var httpCallsPerInvoke: Int
    public var httpJSONBytes: Int
    public var httpFileBytes: Int

    public init(
        timeoutSeconds: Int = PluginContract.defaultTimeoutSeconds,
        httpCallsPerInvoke: Int = PluginContract.defaultHTTPCallsPerInvoke,
        httpJSONBytes: Int = PluginContract.defaultHTTPJSONBytes,
        httpFileBytes: Int = PluginContract.defaultHTTPFileBytes
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.httpCallsPerInvoke = httpCallsPerInvoke
        self.httpJSONBytes = httpJSONBytes
        self.httpFileBytes = httpFileBytes
    }

    enum CodingKeys: String, CodingKey {
        case timeoutSeconds = "timeout_seconds"
        case httpCallsPerInvoke = "http_calls_per_invoke"
        case httpJSONBytes = "http_json_bytes"
        case httpFileBytes = "http_file_bytes"
    }
}

public struct PluginTrigger: Codable, Sendable, Hashable {
    public var kind: PluginTriggerKind
    public var intervalSeconds: Int?
    public var match: PluginTriggerMatch?

    public init(kind: PluginTriggerKind, intervalSeconds: Int? = nil, match: PluginTriggerMatch? = nil) throws {
        self.kind = kind
        self.intervalSeconds = intervalSeconds
        self.match = match
        _ = try validated()
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case intervalSeconds = "interval_seconds"
        case match
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(PluginTriggerKind.self, forKey: .kind)
        let intervalSeconds = try container.decodeIfPresent(Int.self, forKey: .intervalSeconds)
        let match = try container.decodeIfPresent(PluginTriggerMatch.self, forKey: .match)
        try self.init(kind: kind, intervalSeconds: intervalSeconds, match: match)
    }

    public func validated() throws -> PluginTrigger {
        switch kind {
        case .manual:
            return self
        case .schedule:
            let seconds = intervalSeconds ?? 0
            guard seconds >= PluginContract.minScheduleIntervalSeconds else {
                throw PluginManifestError.intervalTooShort(seconds)
            }
            return self
        case .messageInRoom:
            try PluginTrigger.validatePrefix(match?.prefix)
            return self
        }
    }

    public static func validatePrefix(_ raw: String?) throws {
        guard let raw else {
            throw PluginManifestError.invalidTriggerPrefix("")
        }
        guard raw != "/", raw.count >= 2 else {
            throw PluginManifestError.invalidTriggerPrefix(raw)
        }
        guard raw.range(of: #"^[A-Za-z/].+"#, options: .regularExpression) != nil else {
            throw PluginManifestError.invalidTriggerPrefix(raw)
        }
    }
}

public enum PluginTriggerKind: String, Codable, Sendable, Hashable {
    case manual
    case schedule
    case messageInRoom = "message_in_room"
}

public struct PluginTriggerMatch: Codable, Sendable, Hashable {
    public var prefix: String

    public init(prefix: String) {
        self.prefix = prefix
    }
}

public enum PluginEventKind: String, Codable, Sendable, Hashable, CaseIterable {
    case manual
    case schedule
    case messageInRoom = "message_in_room"
    case httpResults = "http_results"
    case uiAction = "ui_action"
    case grantReady = "grant_ready"
    case harness
    case script
}
