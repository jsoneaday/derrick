import Foundation

/// Canonical Derrick script_exec protocol decoded from `script-exec-contract.json`.
public struct ScriptExecContractDocument: Codable, Sendable, Hashable {
    public var version: Int
    public var runtime: ScriptExecRuntimeSpec
    public var io: ScriptExecIOSpec
    public var workflow: ScriptExecWorkflowSpec
    public var output: ScriptExecOutputSpec
    public var agent: ScriptExecAgentSpec
    public var review: ScriptExecReviewSpec
    public var rules: ScriptExecProtocolRules
    public var pluginFactory: ScriptExecPluginFactorySpec

    enum CodingKeys: String, CodingKey {
        case version, runtime, io, workflow, output, agent, review, rules
        case pluginFactory = "plugin_factory"
    }
}

public struct ScriptExecRuntimeSpec: Codable, Sendable, Hashable {
    public var language: String
    public var package: String
    public var binary: String
    public var stdlibOnly: Bool
    public var forbiddenImports: [String]
    public var allowedOSUsage: [String]
    public var exampleGo: String

    enum CodingKeys: String, CodingKey {
        case language, package, binary
        case stdlibOnly = "stdlib_only"
        case forbiddenImports = "forbidden_imports"
        case allowedOSUsage = "allowed_os_usage"
        case exampleGo = "example_go"
    }
}

public struct ScriptExecIOSpec: Codable, Sendable, Hashable {
    public var stdinSchema: String
    public var stdoutSchema: String
    public var guestRuntimeSchema: String

    enum CodingKeys: String, CodingKey {
        case stdinSchema = "stdin_schema"
        case stdoutSchema = "stdout_schema"
        case guestRuntimeSchema = "guest_runtime_schema"
    }
}

public struct ScriptExecWorkflowSpec: Codable, Sendable, Hashable {
    public var firstHopVerbs: [String]
    public var httpResultsEventKind: String
    public var terminalVerbs: [String]
    public var matchHTTPBy: String
    public var httpResultsAccumulate: Bool
    public var postBodyField: String

    enum CodingKeys: String, CodingKey {
        case firstHopVerbs = "first_hop_verbs"
        case httpResultsEventKind = "http_results_event_kind"
        case terminalVerbs = "terminal_verbs"
        case matchHTTPBy = "match_http_by"
        case httpResultsAccumulate = "http_results_accumulate"
        case postBodyField = "post_body_field"
    }
}

public struct ScriptExecOutputSpec: Codable, Sendable, Hashable {
    public var fields: [String: ScriptExecOutputFieldSpec]
    public var forbiddenPatterns: [String]
    public var rawBodyInContentRequiresExplicitUserRequest: Bool

    enum CodingKeys: String, CodingKey {
        case fields
        case forbiddenPatterns = "forbidden_patterns"
        case rawBodyInContentRequiresExplicitUserRequest =
            "raw_body_in_content_requires_explicit_user_request"
    }
}

public struct ScriptExecOutputFieldSpec: Codable, Sendable, Hashable {
    public var purpose: String
    public var hostStripsIncidentalMarkup: Bool?
    public var hostAllowlistSanitizes: Bool?
    public var preferContentForExtractedText: Bool?

    enum CodingKeys: String, CodingKey {
        case purpose
        case hostStripsIncidentalMarkup = "host_strips_incidental_markup"
        case hostAllowlistSanitizes = "host_allowlist_sanitizes"
        case preferContentForExtractedText = "prefer_content_for_extracted_text"
    }
}

public struct ScriptExecAgentSpec: Codable, Sendable, Hashable {
    public var preferDirectURLsOverSERPHTML: Bool
    public var retryWithDifferentURLsOnEmptyFetch: Bool
    public var maxCorrectionAttemptsAfterBlock: Int

    enum CodingKeys: String, CodingKey {
        case preferDirectURLsOverSERPHTML = "prefer_direct_urls_over_serp_html"
        case retryWithDifferentURLsOnEmptyFetch = "retry_with_different_urls_on_empty_fetch"
        case maxCorrectionAttemptsAfterBlock = "max_correction_attempts_after_block"
    }
}

public struct ScriptExecReviewSpec: Codable, Sendable, Hashable {
    public var failFast: Bool
    public var responseSchema: [String: String]
    public var checks: [ScriptExecReviewCheck]
    public var doNotDenyFor: [String]
    public var enforcedElsewhere: [String]

    enum CodingKeys: String, CodingKey {
        case failFast = "fail_fast"
        case responseSchema = "response_schema"
        case checks
        case doNotDenyFor = "do_not_deny_for"
        case enforcedElsewhere = "enforced_elsewhere"
    }
}

public struct ScriptExecReviewCheck: Codable, Sendable, Hashable {
    public var id: String
    public var order: Int
    public var description: String
    public var notes: [String]?
}

public struct ScriptExecProtocolRules: Codable, Sendable, Hashable {
    public var guestHasNoNetwork: Bool
    public var hostPerformsHTTP: Bool
    public var hostAppliesSSRF: Bool
    public var staticVerifierEnforcesImports: Bool
    public var schedulerTimingNotInScript: Bool
    public var deterministicOutputRequired: Bool
    public var stableSortAndDedupeCollections: Bool
    public var noTimeRandomUUIDForVisibleOutput: Bool
    public var matchHTTPResultsByRequestID: Bool

    enum CodingKeys: String, CodingKey {
        case guestHasNoNetwork = "guest_has_no_network"
        case hostPerformsHTTP = "host_performs_http"
        case hostAppliesSSRF = "host_applies_ssrf"
        case staticVerifierEnforcesImports = "static_verifier_enforces_imports"
        case schedulerTimingNotInScript = "scheduler_timing_not_in_script"
        case deterministicOutputRequired = "deterministic_output_required"
        case stableSortAndDedupeCollections = "stable_sort_and_dedupe_collections"
        case noTimeRandomUUIDForVisibleOutput = "no_time_random_uuid_for_visible_output"
        case matchHTTPResultsByRequestID = "match_http_results_by_request_id"
    }
}

public struct ScriptExecPluginFactorySpec: Codable, Sendable, Hashable {
    public var manifest: ScriptExecPluginFactoryManifestSpec
    public var builder: ScriptExecPluginFactoryBuilderSpec
    public var review: ScriptExecPluginFactoryReviewSpec
}

public struct ScriptExecPluginFactoryManifestSpec: Codable, Sendable, Hashable {
    public var hostCreatesManifest: Bool
    public var doNotReturnManifestJSON: Bool
    public var agentPluginSchema: String
    public var entrypoint: String
    public var pluginIDAllowedChars: String
    public var pluginIDForbiddenChars: [String]
    public var roles: [String]
    public var connectorMessagingOps: [String]
    public var secretKinds: [String]
    public var neverEmbedCredentialsInGoSource: Bool
    public var hostListsConnectorsUnderMessaging: Bool

    enum CodingKeys: String, CodingKey {
        case hostCreatesManifest = "host_creates_manifest"
        case doNotReturnManifestJSON = "do_not_return_manifest_json"
        case agentPluginSchema = "agent_plugin_schema"
        case entrypoint
        case pluginIDAllowedChars = "plugin_id_allowed_chars"
        case pluginIDForbiddenChars = "plugin_id_forbidden_chars"
        case roles
        case connectorMessagingOps = "connector_messaging_ops"
        case secretKinds = "secret_kinds"
        case neverEmbedCredentialsInGoSource = "never_embed_credentials_in_go_source"
        case hostListsConnectorsUnderMessaging = "host_lists_connectors_under_messaging"
    }
}

public struct ScriptExecPluginFactoryBuilderSpec: Codable, Sendable, Hashable {
    public var responseKeys: [String]
    public var skillFilesPathPattern: String
    public var emptySkillFilesWhenUnused: Bool
    public var testInputIsSerializedJSONObject: Bool
    public var testInputMustNotBeEmpty: Bool
    public var testInputExercisesTerminalResult: Bool
    public var connectorTestInputUsesHopsArray: Bool
    public var connectorParseJSONHTTPResultsWhenVendorReturnsJSON: Bool

    enum CodingKeys: String, CodingKey {
        case responseKeys = "response_keys"
        case skillFilesPathPattern = "skill_files_path_pattern"
        case emptySkillFilesWhenUnused = "empty_skill_files_when_unused"
        case testInputIsSerializedJSONObject = "test_input_is_serialized_json_object"
        case testInputMustNotBeEmpty = "test_input_must_not_be_empty"
        case testInputExercisesTerminalResult = "test_input_exercises_terminal_result"
        case connectorTestInputUsesHopsArray = "connector_test_input_uses_hops_array"
        case connectorParseJSONHTTPResultsWhenVendorReturnsJSON =
            "connector_parse_json_http_results_when_vendor_returns_json"
    }
}

public struct ScriptExecPluginFactoryReviewSpec: Codable, Sendable, Hashable {
    public var compilationSuccessNotApproval: Bool
    public var responseSchema: [String: String]
    public var rejectNonGoSource: Bool
    public var rejectRawNetworkOutsideHTTPRequestEnvelopes: Bool
    public var rejectMissingStdinRead: Bool
    public var sourceDerivedTitlesMayBeFragments: Bool
    public var rejectUnsupportedDirectTestClaims: Bool
    public var connectorRulesDocument: String

    enum CodingKeys: String, CodingKey {
        case compilationSuccessNotApproval = "compilation_success_not_approval"
        case responseSchema = "response_schema"
        case rejectNonGoSource = "reject_non_go_source"
        case rejectRawNetworkOutsideHTTPRequestEnvelopes =
            "reject_raw_network_outside_http_request_envelopes"
        case rejectMissingStdinRead = "reject_missing_stdin_read"
        case sourceDerivedTitlesMayBeFragments = "source_derived_titles_may_be_fragments"
        case rejectUnsupportedDirectTestClaims = "reject_unsupported_direct_test_claims"
        case connectorRulesDocument = "connector_rules_document"
    }
}

public enum ScriptExecContractError: Error, Equatable, LocalizedError, Sendable {
    case missingResource(String)
    case invalidJSON(String)
    case integrityFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "Missing bundled script_exec contract resource \(name)."
        case .invalidJSON(let name):
            return "Script_exec contract resource \(name) is not valid JSON."
        case .integrityFailed(let detail):
            return "Script_exec contract JSON failed schema checks: \(detail)"
        }
    }
}
