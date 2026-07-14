import Foundation

struct AppDebugConfiguration {
    let isDebugEnabled: Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        if let value = environment["IS_DEBUG"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            isDebugEnabled = value == "true"
            return
        }

        isDebugEnabled = Self.dotEnvValue(
            for: ["IS_DEBUG"],
            currentDirectoryURL: currentDirectoryURL,
            bundleURL: bundleURL
        )?.lowercased() == "true"
    }

    private static func dotEnvValue(
        for keys: [String],
        currentDirectoryURL: URL,
        bundleURL: URL
    ) -> String? {
        var urls: [URL] = []
        var candidate = currentDirectoryURL

        for _ in 0..<4 {
            urls.append(candidate.appendingPathComponent(".env"))
            urls.append(candidate.appendingPathComponent("ui/.env"))
            urls.append(candidate.appendingPathComponent("Resources/.env"))
            urls.append(candidate.appendingPathComponent("ui/Resources/.env"))
            candidate.deleteLastPathComponent()
        }

        if let resourceURL = Bundle(url: bundleURL)?.resourceURL {
            urls.append(resourceURL.appendingPathComponent(".env"))
            urls.append(resourceURL.appendingPathComponent("Resources/.env"))
        }

        urls.append(bundleURL.deletingLastPathComponent().appendingPathComponent(".env"))
        urls.append(bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env"))

        for url in urls {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }

            var values: [String: String] = [:]
            for line in contents.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
                    continue
                }

                let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                values[key] = value
            }

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
