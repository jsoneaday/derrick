import Foundation
import Plugin
import ServiceContracts

/// Turns `plugin.factory.build` MCP JSON into chat-friendly markdown.
enum PluginFactoryUserFacingFormatter {
    struct DisplayOptions {
        var showManualRestartHint: Bool = true

        static let duringAutomaticRetry = DisplayOptions(showManualRestartHint: false)
    }

    static func displayText(
        from rawResult: String,
        options: DisplayOptions = DisplayOptions()
    ) -> String {
        let trimmed = rawResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let outcome = ToolExecutionOutcome.decode(from: trimmed) else {
            return trimmed
        }

        if outcome.status == .completed {
            return successText(from: outcome)
        }
        if outcome.indicatesFailure {
            return failureText(from: outcome, options: options)
        }
        return ToolFollowUpFormatter.formatOutcome(
            toolName: "plugin.factory.build",
            outcome: outcome,
            stdoutCap: 4_000
        )
    }

    private static func successText(from outcome: ToolExecutionOutcome) -> String {
        guard let value = outcome.output?.value,
              let data = value.data(using: .utf8),
              let receipt = try? JSONDecoder().decode(FactoryReceipt.self, from: data) else {
            return "**Plugin saved.**"
        }
        var lines = [
            "**Plugin approved and saved.**",
            "",
            "- Plugin: `\(receipt.pluginID)`",
            "- Version: `\(receipt.version)`",
        ]
        let summary = receipt.reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            lines.append("")
            lines.append(summary)
        }
        if let secrets = receipt.secrets, !secrets.isEmpty {
            lines.append("")
            lines.append(
                "Credentials: \(secrets.map(\.label).joined(separator: ", ")). "
                    + "You will be prompted when you connect or run the plugin."
            )
        }
        return lines.joined(separator: "\n")
    }

    static func savedPluginNextStepText(
        pluginID: String,
        isMessagingConnector: Bool,
        credentialsReady: Bool,
        willNavigateToMessaging: Bool
    ) -> String {
        if isMessagingConnector {
            if credentialsReady {
                if willNavigateToMessaging {
                    return """
                    **Plugin approved and saved.**

                    Open **Messaging → \(pluginID)** to connect and sync. Taking you there now.
                    """
                }
                return """
                **Plugin approved and saved.**

                Open **Messaging → \(pluginID)** to connect and sync.
                """
            }
            return """
            Plugin **\(pluginID)** was saved. Open **Messaging → \(pluginID)** to add credentials and connect.
            """
        }
        if credentialsReady {
            return """
            **Plugin approved and saved.**

            Run **\(pluginID)** from Plugins when you are ready.
            """
        }
        return """
        Plugin **\(pluginID)** was saved. Add its credentials when you are ready to run it.
        """
    }

    private static func failureText(
        from outcome: ToolExecutionOutcome,
        options: DisplayOptions
    ) -> String {
        var lines = [
            "**Plugin creation could not finish.**",
            "",
            stageLine(outcome.stage),
        ]
        let reasons = outcome.diagnostics
            .map(\.message)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if reasons.isEmpty {
            lines.append("")
            lines.append("No additional detail was returned.")
        } else {
            lines.append("")
            lines.append("**What went wrong**")
            for reason in reasons.prefix(6) {
                lines.append("- \(reason)")
            }
        }
        if options.showManualRestartHint {
            lines.append("")
            lines.append("Adjust the plugin factory goal and try `plugin_factory_build` again.")
        }
        return lines.joined(separator: "\n")
    }

    private static func stageLine(_ stage: ToolExecutionOutcome.Stage) -> String {
        let label: String
        switch stage {
        case .validation:
            label = "Draft validation"
        case .review:
            label = "Safety and alignment review"
        case .compilation:
            label = "Packaging"
        case .execution:
            label = "Plugin test run"
        case .persistence:
            label = "Saving to library"
        case .network:
            label = "Network"
        case .timeout:
            label = "Timed out"
        case .none:
            label = "Factory"
        }
        return "Stage: **\(label)**"
    }
}

private struct FactoryReceipt: Decodable {
    let pluginID: String
    let version: String
    let reviewSummary: String
    let secrets: [PluginSecretDescriptor]?

    enum CodingKeys: String, CodingKey {
        case pluginID = "plugin_id"
        case version
        case reviewSummary = "review_summary"
        case secrets
    }
}
