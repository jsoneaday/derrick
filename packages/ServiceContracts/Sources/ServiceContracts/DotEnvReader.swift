import Foundation

/// Shared `.env` discovery for UI, XPC, and derrickd.
///
/// Local dev: copy `.env.example` to `ui/ui/Resources/.env`.
/// The UI build copies that file into `Derrick.app/Contents/Resources/.env`.
public enum DotEnvReader: Sendable {
    public static let repositoryRelativePath = "ui/ui/Resources/.env"
    public static let secretModeKey = "UI_SECRET_MODE"

    public enum SecretSourceMode: String, Sendable {
        case keychain
        case dotenv
    }

    public static var usesDotenvOnly: Bool {
        secretSourceMode() == .dotenv
    }

    public static func secretSourceMode(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) -> SecretSourceMode {
        if let raw = environment[secretModeKey],
           let mode = SecretSourceMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return mode
        }
        if let raw = value(
            for: secretModeKey,
            environment: environment,
            bundleURL: bundleURL,
            currentDirectoryURL: currentDirectoryURL
        ), let mode = SecretSourceMode(rawValue: raw) {
            return mode
        }
        return .keychain
    }

    public static func value(
        for key: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) -> String? {
        values(
            environment: environment,
            bundleURL: bundleURL,
            currentDirectoryURL: currentDirectoryURL
        )?[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    public static func firstValue(
        for keys: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) -> String? {
        for key in keys {
            if let value = value(
                for: key,
                environment: environment,
                bundleURL: bundleURL,
                currentDirectoryURL: currentDirectoryURL
            ) {
                return value
            }
        }
        return nil
    }

    public static func values(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) -> [String: String]? {
        for url in searchURLs(bundleURL: bundleURL, currentDirectoryURL: currentDirectoryURL) {
            if let parsed = parse(at: url) {
                return parsed
            }
        }
        return nil
    }

    /// First `.env` file on the search path (for error messages).
    public static func preferredDotEnvURL(
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) -> URL {
        for url in searchURLs(bundleURL: bundleURL, currentDirectoryURL: currentDirectoryURL) {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return URL(fileURLWithPath: repositoryRelativePath, isDirectory: false)
    }

    public static func missingSecretMessage(variableKeys: [String]) -> String {
        let keys = variableKeys.joined(separator: " or ")
        return """
        Derrick is using `.env` for secrets (`UI_SECRET_MODE=dotenv`). Keychain is not used.

        Add \(keys) to \(repositoryRelativePath), then quit and reopen Derrick.
        """
    }

    public static func searchURLs(bundleURL: URL, currentDirectoryURL: URL) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        func append(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            urls.append(url)
        }

        var candidate = currentDirectoryURL
        for _ in 0..<12 {
            append(candidate.appendingPathComponent(repositoryRelativePath))
            append(candidate.appendingPathComponent(".env"))
            append(candidate.appendingPathComponent("ui/.env"))
            append(candidate.appendingPathComponent("Resources/.env"))
            candidate.deleteLastPathComponent()
        }

        if let resourceURL = Bundle(url: bundleURL)?.resourceURL {
            append(resourceURL.appendingPathComponent(".env"))
            append(resourceURL.appendingPathComponent("Resources/.env"))
        }

        var dir = bundleURL.standardizedFileURL
        for _ in 0..<10 {
            if dir.pathExtension == "app" {
                append(dir.appendingPathComponent("Contents/Resources/.env"))
            }
            if dir.lastPathComponent == "XPCServices" {
                let contents = dir.deletingLastPathComponent()
                append(contents.appendingPathComponent("Resources/.env"))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        if let host = DerrickAppSupport.hostUIApplicationURL(bundleURL: bundleURL) {
            append(host.appendingPathComponent("Contents/Resources/.env"))
        }

        append(bundleURL.deletingLastPathComponent().appendingPathComponent(".env"))
        append(
            bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(".env")
        )

        return urls
    }

    public static func parse(at url: URL) -> [String: String]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        var values: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }
        return values.isEmpty ? nil : values
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
