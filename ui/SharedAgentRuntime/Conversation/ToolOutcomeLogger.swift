import Foundation
import MCPToolCatalog
import Structure

/// Emits concise, UI-visible lines for high-signal tool outcomes.
enum ToolOutcomeLogger {
    static func log(toolName: String, rawText: String) {
        switch toolName {
        case AllowedMCPTool.pluginFactoryBuild.rawValue:
            logPluginFactory(rawText)
        case AllowedMCPTool.webCrawl.rawValue:
            logWebCrawl(rawText)
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
}
