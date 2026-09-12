import Foundation

/// Renders the bundled script_exec protocol for agent, builder, and reviewer prompts.
public enum ScriptExecContractPrompts: Sendable {
    public static func builderGuide() -> String {
        dumpOrUnavailable(preamble: """
        Offline Go guest rules come only from this protocol JSON and the wire schemas below. \
        Do not invent requirements that are not in the JSON.
        """)
    }

    public static func reviewerGuide() -> String {
        dumpOrUnavailable(preamble: """
        You are a reviewer for script_exec declarations. Review against script-exec-contract.json only. \
        If a rule is not in the JSON, do not require it. Apply review.checks in order; when review.fail_fast \
        is true, return on the first failing check. Return only valid JSON matching review.response_schema.
        """)
    }

    public static func pluginFactoryBuilderGuide() -> String {
        dumpOrUnavailable(preamble: """
        Plugin factory builder rules come only from script-exec-contract.json (plugin_factory, runtime, \
        workflow, output, rules) and connector-contract.json when building a connector. Do not invent \
        requirements that are not in those JSON documents.
        """)
    }

    public static func pluginFactoryReviewerGuide() -> String {
        dumpOrUnavailable(preamble: """
        You are Derrick's independent plugin alignment and safety reviewer. Review guest go_source against \
        script-exec-contract.json (runtime, workflow, output, rules, plugin_factory.review). If a guest rule \
        is not in the JSON, do not require it. For connector plugins also apply connector-contract.json below. \
        Return exactly one JSON object matching plugin_factory.review.response_schema.
        """)
    }

    public static func dump(preamble: String) throws -> String {
        _ = try ScriptExecContractStore.loadProtocol()
        var lines: [String] = [preamble, "", "--- script-exec-contract.json ---"]
        lines.append(try ScriptExecContractStore.loadProtocolText())
        lines.append("")
        lines.append("--- \(GuestContract.Schema.guestRuntime.rawValue) ---")
        lines.append(try GuestContract.loadSchemaText(.guestRuntime))
        lines.append("")
        lines.append("--- \(GuestContract.Schema.hopEvent.rawValue) ---")
        lines.append(try GuestContract.loadSchemaText(.hopEvent))
        lines.append("")
        lines.append("--- \(GuestContract.Schema.envelopeList.rawValue) ---")
        lines.append(try GuestContract.loadSchemaText(.envelopeList))
        return lines.joined(separator: "\n")
    }

    private static func dumpOrUnavailable(preamble: String) -> String {
        (try? dump(preamble: preamble)) ?? "Script_exec contract JSON failed to load."
    }
}
