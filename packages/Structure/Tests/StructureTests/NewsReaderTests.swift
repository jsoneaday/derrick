import Foundation
import Testing
import Structure

@Suite struct NewsReaderTests {
    @Test func paywallWarningIsUserFacing() {
        #expect(NewsPaywall.userWarning.localizedCaseInsensitiveContains("paywall"))
        #expect(NewsPaywall.userWarning.localizedCaseInsensitiveContains("not supported"))
    }

    @Test func preflightRejectsPaywalledArticleAllowsFeed() {
        #expect(
            NewsPaywall.preflightRejection(
                url: URL(string: "https://www.nytimes.com/2024/01/01/world.html")!
            ) != nil
        )
        #expect(
            NewsPaywall.preflightRejection(
                url: URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml")!
            ) == nil
        )
    }

    @Test func inferNewsModeMapsSummaryCrawlAndRSS() {
        let summary = PluginSkillDraft(goal: "Give me a summary of tech news")
        #expect(PluginSkillDraftPlanner.inferNewsMode(from: summary) == .summary)

        let crawl = PluginSkillDraft(goal: "Crawl the BBC homepage for headlines")
        #expect(PluginSkillDraftPlanner.inferNewsMode(from: crawl) == .list)

        let rss = PluginSkillDraft(goal: "Fetch tech headlines from Google News RSS")
        #expect(PluginSkillDraftPlanner.inferNewsMode(from: rss) == .rss)
    }

    @Test func legacySummariesModeDecodesToSummary() throws {
        struct Wrapper: Decodable { let mode: NewsReaderMode }
        let wrapper = try JSONDecoder.service.decode(
            Wrapper.self,
            from: Data(#"{"mode":"summaries"}"#.utf8)
        )
        #expect(wrapper.mode == .summary)
    }

    @Test func presetSourcesUsePublicFeedsNotPaywalledArticlePages() {
        for preset in NewsPresetSource.allCases {
            let url = URL(string: preset.source.url)!
            #expect(
                NewsPaywall.preflightRejection(url: url) == nil,
                "Expected \(preset.source.label) feed to pass paywall preflight"
            )
        }
    }

    @Test func workerRequestEncodesModeAndSources() throws {
        let request = NewsReaderWorkerRequest(
            mode: .rss,
            sources: [NewsSource(label: "BBC", url: "https://feeds.bbci.co.uk/news/rss.xml")],
            topics: ["Tech"],
            maxCount: 10,
            contextHint: "tech-news"
        )
        let json = try request.encodedJSON()
        let decoded = try JSONDecoder.service.decode(NewsReaderWorkerRequest.self, from: json)
        #expect(decoded.mode == .rss)
        #expect(decoded.sources.count == 1)
        #expect(decoded.topics == ["Tech"])
    }
}
