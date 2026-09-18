import Testing
import Structure

@Suite struct AgentPluginSpecTests {
    @Test func forcedBlockPrefersLatestDisclaimer() {
        let block = AgentPluginSpec.forcedPromptBlock(
            summary: "Skills require SKILL.md",
            sourceURL: AgentPluginSpec.publishedURL.absoluteString
        )
        #expect(block.contains("Prefer the latest published"))
        #expect(block.contains("agent-plugins.org/specification"))
        #expect(block.contains("Skills require SKILL.md"))
        #expect(block.contains("skills/<name>/SKILL.md"))
    }

    @Test func bundledFallbackMentionsManifestAndSkills() {
        let summary = AgentPluginSpec.bundledFallbackSummary()
        #expect(summary.contains("plugin.json"))
        #expect(summary.contains("SKILL.md"))
    }

    @Test func summaryParsesCrawlPagesPayload() {
        let payload = #"{"pages":[{"title":"Agent Plugins","text":"plugin.json is required. Skills need SKILL.md."}]}"#
        let summary = AgentPluginSpec.summary(fromCrawlToolText: payload)
        #expect(summary?.contains("plugin.json") == true)
        #expect(summary?.contains("SKILL.md") == true)
    }
}
