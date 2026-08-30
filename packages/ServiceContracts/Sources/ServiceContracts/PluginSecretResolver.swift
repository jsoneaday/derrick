import Foundation

/// Resolves declared plugin secrets from Keychain and/or dev `.env` files.
public enum PluginSecretResolver: Sendable {
    private enum SourceMode: String, Sendable {
        case keychain
        case dotenv
    }

    public static var usesDotenvOnly: Bool { mode() == .dotenv }

    public static func resolve(pluginID: String, fieldID: String) -> String? {
        let keys = environmentKeys(pluginID: pluginID, fieldID: fieldID)
        switch mode() {
        case .dotenv:
            return firstValue(for: keys, in: .dotenv) ?? firstValue(for: keys, in: .environment)
        case .keychain:
            return (try? PluginSecretKeychain.loadFromKeychain(pluginID: pluginID, fieldID: fieldID))
                ?? firstValue(for: keys, in: .environment)
                ?? firstValue(for: keys, in: .dotenv)
        }
    }

    public static func environmentKeys(pluginID: String, fieldID: String) -> [String] {
        var keys = knownAliases(pluginID: pluginID, fieldID: fieldID)
        let pluginToken = pluginID.uppercased().replacingOccurrences(of: "-", with: "_")
        let fieldToken = fieldID.uppercased()
        keys.append("PLUGIN_\(pluginToken)_\(fieldToken)")
        return keys
    }

    private static func knownAliases(pluginID: String, fieldID: String) -> [String] {
        if pluginID == "slack-connection", fieldID == "bot_token" {
            return ["SLACK_BOT_KEY", "SLACK_API_KEY"]
        }
        return []
    }

    private enum LookupSource {
        case dotenv
        case environment
    }

    private static func firstValue(for keys: [String], in source: LookupSource) -> String? {
        switch source {
        case .environment:
            for key in keys {
                if let value = ProcessInfo.processInfo.environment[key]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !value.isEmpty {
                    return value
                }
            }
            return nil
        case .dotenv:
            for url in dotEnvSearchURLs() {
                guard let values = parseDotEnv(at: url) else { continue }
                for key in keys {
                    if let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !value.isEmpty {
                        return value
                    }
                }
            }
            return nil
        }
    }

    private static func mode() -> SourceMode {
        if let raw = ProcessInfo.processInfo.environment["UI_SECRET_MODE"],
           let mode = SourceMode(rawValue: raw) {
            return mode
        }
        if let raw = dotEnvValue(for: ["UI_SECRET_MODE"]),
           let mode = SourceMode(rawValue: raw) {
            return mode
        }
        return .keychain
    }

    private static func dotEnvValue(for keys: [String]) -> String? {
        firstValue(for: keys, in: .dotenv)
    }

    private static func dotEnvSearchURLs() -> [URL] {
        let currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let bundleURL = Bundle.main.bundleURL
        var urls: [URL] = []
        var candidate = currentDirectoryURL

        for _ in 0..<12 {
            urls.append(candidate.appendingPathComponent(".env"))
            urls.append(candidate.appendingPathComponent("ui/.env"))
            urls.append(candidate.appendingPathComponent("ui/ui/Resources/.env"))
            candidate.deleteLastPathComponent()
        }

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(".env"))
            urls.append(resourceURL.appendingPathComponent("ui/.env"))
            urls.append(resourceURL.appendingPathComponent("Resources/.env"))
        }

        urls.append(contentsOf: hostAppDotEnvURLs(from: bundleURL))
        urls.append(bundleURL.deletingLastPathComponent().appendingPathComponent(".env"))
        urls.append(
            bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env")
        )

        return urls
    }

    private static func hostAppDotEnvURLs(from bundleURL: URL) -> [URL] {
        var urls: [URL] = []
        var dir = bundleURL.standardizedFileURL

        for _ in 0..<10 {
            if dir.pathExtension == "app" {
                urls.append(dir.appendingPathComponent("Contents/Resources/.env"))
                urls.append(dir.appendingPathComponent("Contents/Resources/ui/.env"))
                break
            }
            if dir.lastPathComponent == "XPCServices" {
                let contents = dir.deletingLastPathComponent()
                urls.append(contents.appendingPathComponent("Resources/.env"))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        return urls
    }

    private static func parseDotEnv(at url: URL) -> [String: String]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        var values: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
                continue
            }

            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }

        return values.isEmpty ? nil : values
    }
}
