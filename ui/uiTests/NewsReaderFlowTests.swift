import Foundation
import Testing
import Structure

@Suite struct NewsReaderFlowTests {
    @Test func skillDraftForTechNewsSummaryRequest() {
        var draft = PluginSkillDraft()
        PluginSkillDraftPlanner.applyGoal(
            "Give me summaries of today's tech news",
            to: &draft,
            existingPluginIDs: []
        )
        draft.pluginName = "tech-news"
        draft.newsSourceURLs = [
            NewsPresetSource.googleNews.source.url,
            NewsPresetSource.wsj.source.url,
        ]
        draft.newsTopics = ["Tech"]
        draft.examples = [
            PluginSkillDraft.Example(
                userSays: "Give me summaries of tech news",
                pluginDoes: "fetch headlines and summarize them with source links"
            ),
        ]

        #expect(draft.plannedKind == .newsDigest)
        #expect(PluginSkillDraftPlanner.inferNewsMode(from: draft) == .summary)
        #expect(draft.pluginName == "tech-news")
        #expect(draft.newsSourceURLs.contains(NewsPresetSource.googleNews.source.url))
        #expect(draft.newsSourceURLs.contains(NewsPresetSource.wsj.source.url))
    }

    @Test func newsReaderWorkerRequestMatchesWizardSpec() throws {
        let sources = [
            NewsPresetSource.googleNews.source,
            NewsPresetSource.wsj.source,
        ]
        let spec = NewsReaderSpec(
            name: "tech-news",
            topics: ["Tech"],
            sources: sources,
            mode: .summary,
            maxCount: 20,
            schedule: .off
        )
        let request = NewsReaderWorkerRequest(
            mode: spec.mode,
            sources: spec.sources,
            topics: spec.topics,
            maxCount: spec.maxCount,
            contextHint: spec.name
        )
        let json = try request.encodedJSON()
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(object?["mode"] as? String == "summary")
        #expect((object?["sources"] as? [[String: Any]])?.count == 2)
    }
}
