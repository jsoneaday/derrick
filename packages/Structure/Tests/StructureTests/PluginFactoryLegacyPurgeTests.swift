import Testing
import Structure

@Suite struct PluginFactoryLegacyPurgeTests {
    @Test func matchesSlackPluginIDs() {
        #expect(PluginFactoryLegacyPurge.isLegacySlackPluginID("slack-connection"))
        #expect(PluginFactoryLegacyPurge.isLegacySlackPluginID("Slack-Bot"))
        #expect(PluginFactoryLegacyPurge.isLegacySlackPluginID("my-slack-helper"))
        #expect(!PluginFactoryLegacyPurge.isLegacySlackPluginID("discord-bot"))
        #expect(!PluginFactoryLegacyPurge.isLegacySlackPluginID("weather-tool"))
    }
}
