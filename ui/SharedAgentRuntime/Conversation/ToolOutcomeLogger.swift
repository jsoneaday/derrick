import Foundation
import Structure

/// Emits concise, UI-visible lines for high-signal tool outcomes.
enum ToolOutcomeLogger {
    static func log(toolName: String, rawText: String) {
        switch toolName {
        case AllowedMCPTool.pluginFactoryBuild.rawValue:
            logPluginFactory(rawText)
        case AllowedMCPTool.webCrawl.rawValue:
            logWebCrawl(rawText)
        case AllowedMCPTool.webSearch.rawValue:
            logWebSearch(rawText)
        default:
            break
        }
    }

    private static func logPluginFactory(_ rawText: String) {
        guard let outcome = ToolExecutionOutcome.decode(from: rawText) else {
            debugLog("[plugin_factory] finished with non-JSON outcome")
            return
        }

        if outcome.status == .completed {
            if let pluginID = pluginID(from: outcome) {
                debugLog("[plugin_factory] saved plugin=\(pluginID)")
            } else {
                debugLog("[plugin_factory] completed")
            }
            return
        }

        debugLog(
            "[plugin_factory] failed status=\(outcome.status.rawValue) "
                + "stage=\(outcome.stage.rawValue)"
        )
        let reasons = outcome.diagnostics
            .map(\.message)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if reasons.isEmpty {
            debugLog("[plugin_factory] no reviewer diagnostics returned")
            return
        }
        for (index, reason) in reasons.prefix(8).enumerated() {
            debugLog("[plugin_factory] reason \(index + 1): \(reason)")
        }
    }

    private static func logWebCrawl(_ rawText: String) {
        guard let outcome = ToolExecutionOutcome.decode(from: rawText) else {
            debugLog("[web.crawl] finished with non-JSON outcome")
            return
        }

        if outcome.status == .completed {
            let pages = pageCount(from: outcome)
            if let pages {
                debugLog("[web.crawl] ok pages=\(pages)")
            } else {
                debugLog("[web.crawl] ok")
            }
            for line in crawlPageLines(from: outcome).prefix(6) {
                debugLog("[web.crawl] \(line)")
            }
            return
        }

        debugLog(
            "[web.crawl] failed status=\(outcome.status.rawValue) "
                + "stage=\(outcome.stage.rawValue)"
        )
        for diagnostic in outcome.diagnostics.prefix(4) {
            let message = diagnostic.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { continue }
            debugLog("[web.crawl] \(message)")
        }
    }

    private static func logWebSearch(_ rawText: String) {
        guard let outcome = ToolExecutionOutcome.decode(from: rawText) else {
            debugLog("[web.search] finished with non-JSON outcome")
            return
        }

        if outcome.status == .completed {
            let hits = hitCount(from: outcome)
            if let hits {
                debugLog("[web.search] ok hits=\(hits)")
            } else {
                debugLog("[web.search] ok")
            }
            for url in hitURLs(from: outcome).prefix(5) {
                debugLog("[web.search] hit \(url)")
            }
            return
        }

        debugLog(
            "[web.search] failed status=\(outcome.status.rawValue) "
                + "stage=\(outcome.stage.rawValue)"
        )
        for diagnostic in outcome.diagnostics.prefix(4) {
            let message = diagnostic.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { continue }
            debugLog("[web.search] \(message)")
        }
    }

    private static func pluginID(from outcome: ToolExecutionOutcome) -> String? {
        guard let value = outcome.output?.value,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pluginID = object["plugin_id"] as? String else {
            return nil
        }
        let trimmed = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func pageCount(from outcome: ToolExecutionOutcome) -> Int? {
        guard let value = outcome.output?.value,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = object["pages"] as? [Any] else {
            return nil
        }
        return pages.count
    }

    private static func crawlPageLines(from outcome: ToolExecutionOutcome) -> [String] {
        guard let value = outcome.output?.value,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = object["pages"] as? [[String: Any]] else {
            return []
        }
        return pages.compactMap { page in
            let url = (page["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !url.isEmpty else { return nil }
            let status = page["status_code"] as? Int ?? page["statusCode"] as? Int
            if let status {
                return "page \(url) status=\(status)"
            }
            return "page \(url)"
        }
    }

    private static func hitCount(from outcome: ToolExecutionOutcome) -> Int? {
        guard let value = outcome.output?.value,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = object["hits"] as? [Any] else {
            return nil
        }
        return hits.count
    }

    private static func hitURLs(from outcome: ToolExecutionOutcome) -> [String] {
        guard let value = outcome.output?.value,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = object["hits"] as? [[String: Any]] else {
            return []
        }
        return hits.compactMap { hit in
            let url = (hit["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return url.isEmpty ? nil : url
        }
    }
}
