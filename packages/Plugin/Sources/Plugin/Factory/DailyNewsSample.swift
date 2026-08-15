import Foundation

/// Shipped first sample. No auth. One public news host via host HTTP.
public enum DailyNewsSample: Sendable {
    public static let pluginID = "daily-news"
    public static let version = "1.0.0"
    public static let description = "Headlines from one public news host."

    public static let handle = """
    import { netFetch, httpBody, stripMarkup, type HandleEvent, type HandleResult } from "derrick";

    const newsURL = "https://www.bbc.com/news";

    export function handle(event: HandleEvent): HandleResult {
      if (event.kind === "http_results") {
        const html = event.http_results?.[0]?.body ?? "";
        const titles = collectHeadlines(html);
        const summary = titles.length > 0
          ? titles.map((title, index) => `${index + 1}. ${title}`).join("\\n")
          : "No headlines parsed from the page.";
        return [
          { verb: "result.emit", title: "Daily news", summary },
          { verb: "message.post", text: summary },
        ];
      }
      return netFetch({ url: newsURL });
    }

    function collectHeadlines(html: string): string[] {
      const seen = new Set<string>();
      const titles: string[] = [];
      const push = (raw: string) => {
        const title = raw
          .replace(/<!\\[CDATA\\[/gi, "")
          .replace(/\\]\\]>/g, "")
          .replace(/<[^>]+>/g, " ")
          .replace(/\\s+/g, " ")
          .trim();
        if (title.length < 8 || seen.has(title)) return;
        seen.add(title);
        titles.push(title);
      };
      for (const match of html.matchAll(/<item\\b[\\s\\S]*?<title[^>]*>([\\s\\S]*?)<\\/title>/gi)) {
        push(match[1]);
        if (titles.length >= 8) return titles;
      }
      for (const match of html.matchAll(/<(?:h1|h2|h3)[^>]*>([^<]{12,160})<\\/(?:h1|h2|h3)>/gi)) {
        push(match[1]);
        if (titles.length >= 8) return titles;
      }
      return titles;
    }
    """

    public static func draft() -> FactoryPackageDraft {
        FactoryPackageDraft(
            goal: "Daily headlines from one public news host. No login.",
            pluginID: pluginID,
            version: version,
            description: description,
            handle: handle,
            volumeEnabled: false,
            fixturesJSON: #"[{"kind":"harness","params":{"sample":true}}]"#
        )
    }
}
