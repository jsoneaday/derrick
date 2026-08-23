import Foundation

/// Receives crawler events and owns crawl-specific state.
public protocol CrawlerDelegate: Sendable {
    func crawler(_ crawler: Crawler, shouldVisitUrl url: URL) async -> Crawler.Decision
    func crawler(_ crawler: Crawler, willVisitUrl url: URL) async
    func crawler(_ crawler: Crawler, visit url: URL) async throws
    func crawler(_ crawler: Crawler, didVisit url: URL) async
    func crawler(_ crawler: Crawler, didFindLinks links: Set<Crawler.Link>, at url: URL) async
    func crawler(_ crawler: Crawler, didSkip url: URL, reason: Crawler.SkipReason) async
    func crawler(_ crawler: Crawler) async -> URL?
    func crawlerDidFinish(_ crawler: Crawler) async
}
