import Foundation
import ServiceContracts
import Testing
@testable import ui

@Suite struct PluginFactoryUserFacingFormatterTests {
    @Test func formatsBlockedReviewFailureWithoutRawJSON() throws {
        let json = try ToolExecutionOutcome.failure(
            status: .blocked,
            stage: .review,
            diagnostics: [
                ToolExecutionOutcome.Diagnostic(
                    code: "plugin_factory_review_summary",
                    message: "Connector tests are incomplete."
                ),
                ToolExecutionOutcome.Diagnostic(
                    code: "plugin_factory_review_finding",
                    message: "blocking: poll_inbox only works when vendor_thread_id is set."
                ),
            ],
            retry: ToolExecutionOutcome.Retry(allowed: false)
        ).encodedJSON()

        let text = PluginFactoryUserFacingFormatter.displayText(from: json)
        #expect(text.contains("**Plugin creation could not finish.**"))
        #expect(text.contains("Safety and alignment review"))
        #expect(text.contains("poll_inbox only works"))
        #expect(text.contains("plugin_factory_build"))
        #expect(!text.contains("\"status\":\"blocked\""))
    }

    @Test func formatsSuccessReceipt() throws {
        let receipt = """
        {"ok":true,"plugin_id":"slack-connection","version":"0.1.0",\
        "content_hash":"abc","review_summary":"Slack connector ready.","secrets":[]}
        """
        let json = try ToolExecutionOutcome.completed(
            output: ToolExecutionOutcome.Output(format: .json, value: receipt)
        ).encodedJSON()

        let text = PluginFactoryUserFacingFormatter.displayText(from: json)
        #expect(text.contains("**Plugin approved and saved.**"))
        #expect(text.contains("`slack-connection`"))
        #expect(text.contains("Slack connector ready."))
    }

    @Test func savedConnectorPluginNavigatesToMessaging() {
        let text = PluginFactoryUserFacingFormatter.savedPluginNextStepText(
            pluginID: "slack-connector",
            isMessagingConnector: true,
            credentialsReady: true,
            willNavigateToMessaging: true
        )
        #expect(text.contains("**Plugin approved and saved.**"))
        #expect(text.contains("Messaging → slack-connector"))
        #expect(text.contains("Taking you there now"))
        #expect(!text.contains("Running it now"))
    }

    @Test func savedConnectorWithoutCredentialsPointsToMessaging() {
        let text = PluginFactoryUserFacingFormatter.savedPluginNextStepText(
            pluginID: "slack-connector",
            isMessagingConnector: true,
            credentialsReady: false,
            willNavigateToMessaging: false
        )
        #expect(text.contains("Messaging → slack-connector"))
        #expect(text.contains("add credentials"))
    }

    @Test func savedNonConnectorPluginDoesNotMentionMessaging() {
        let text = PluginFactoryUserFacingFormatter.savedPluginNextStepText(
            pluginID: "weather-tool",
            isMessagingConnector: false,
            credentialsReady: true,
            willNavigateToMessaging: false
        )
        #expect(text.contains("Run **weather-tool** from Plugins"))
        #expect(!text.contains("Messaging"))
    }
}
