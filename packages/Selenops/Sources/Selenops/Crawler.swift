import Foundation
import Structure
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftSoup

/// A small recursive crawler engine.
///
/// This is a vendored, Linux-compatible copy of Selenops pinned from
/// 1amageek/Selenops revision 529a84a2c0bc4bc15e0825fd505c0f7a362a0ea2.
/// Fetching, scope checks, and result storage remain delegate-owned.
public final class Crawler: Sendable {
    public enum Decision: Sendable {
        case visit
        case skip(SkipReason)
    }

    public enum SkipReason: Sendable {
        case invalidURL
        case unsupportedFileType
        case businessLogic(String)
        case error(Error)
    }

    private let delegate: any CrawlerDelegate

    public init(delegate: any CrawlerDelegate) {
        self.delegate = delegate
    }

    public func start(url: URL) async {
        await crawl(url: url)
    }

    private func crawl(url: URL) async {
        switch await delegate.crawler(self, shouldVisitUrl: url) {
        case .visit:
            await visit(page: url)
        case .skip(let reason):
            await delegate.crawler(self, didSkip: url, reason: reason)
        }

        while let pageToVisit = await delegate.crawler(self) {
            switch await delegate.crawler(self, shouldVisitUrl: pageToVisit) {
            case .visit:
                await visit(page: pageToVisit)
            case .skip(let reason):
                await delegate.crawler(self, didSkip: pageToVisit, reason: reason)
            }
        }
        await delegate.crawlerDidFinish(self)
    }

    private func visit(page url: URL) async {
        do {
            await delegate.crawler(self, willVisitUrl: url)
            try await delegate.crawler(self, visit: url)
            await delegate.crawler(self, didVisit: url)
        } catch {
            await delegate.crawler(self, didSkip: url, reason: .error(error))
        }
    }

    public func parseLinks(from html: String, at url: URL) async {
        do {
            let document = try SwiftSoup.parse(html, url.absoluteString)
            let anchorElements = try document.select("a").array()
            var links: Set<Link> = []

            for anchor in anchorElements {
                let href = try anchor.attr("href")
                guard let resolvedURL = URL(string: href, relativeTo: url)?.absoluteURL else {
                    continue
                }
                guard let scheme = resolvedURL.scheme?.lowercased(),
                      ["http", "https"].contains(scheme)
                else {
                    continue
                }

                var components = URLComponents(
                    url: resolvedURL,
                    resolvingAgainstBaseURL: true
                )
                components?.fragment = nil
                components?.queryItems = nil
                guard let normalizedURL = components?.url else { continue }

                var title = try anchor.attr("aria-label")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty, let image = try anchor.select("img[alt]").first() {
                    title = try image.attr("alt")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if title.isEmpty {
                    title = try anchor.attr("title")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if title.isEmpty {
                    title = try anchor.text()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if title.isEmpty {
                    title = normalizedURL.absoluteString
                }

                links.insert(Link(url: normalizedURL, title: title))
            }

            await delegate.crawler(self, didFindLinks: links, at: url)
        } catch {
            await delegate.crawler(
                self,
                didSkip: url,
                reason: .error(error)
            )
        }
    }

    public static func detectEncoding(
        from response: HTTPURLResponse,
        data: Data
    ) -> String.Encoding {
        if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
           let charsetPart = contentType.components(separatedBy: "charset=").last {
            let charset = charsetPart
                .components(separatedBy: ";")
                .first?
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) ?? ""
            switch charset.lowercased() {
            case "shift_jis", "shift-jis", "shiftjis":
                return .shiftJIS
            case "euc-jp":
                return .japaneseEUC
            case "iso-2022-jp":
                return .iso2022JP
            case "utf-8":
                return .utf8
            default:
                break
            }
        }

        if let content = String(data: data, encoding: .isoLatin1),
           let metaCharset = content.range(
            of: "charset=",
            options: [.caseInsensitive]
           ) {
            let startIndex = metaCharset.upperBound
            let endIndex = content[startIndex...].firstIndex {
                !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_"
            } ?? content.endIndex
            switch content[startIndex..<endIndex].lowercased() {
            case "shift_jis", "shift-jis", "shiftjis":
                return .shiftJIS
            case "euc-jp":
                return .japaneseEUC
            case "iso-2022-jp":
                return .iso2022JP
            case "utf-8":
                return .utf8
            default:
                break
            }
        }

        return .utf8
    }
}
