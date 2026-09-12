import Foundation
import Testing
import Structure

@Suite struct NewsPaywallTests {
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

    @Test func canonicalFetchURLUpgradesGeneralGoogleNewsRSSForTechHint() {
        let url = URL(string: "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en")!
        let canonical = NewsSourceURL.canonicalFetchURL(url, contextHint: "tech-news Tech")
        #expect(canonical.path.contains("/headlines/section/topic/TECHNOLOGY"))
    }
}
