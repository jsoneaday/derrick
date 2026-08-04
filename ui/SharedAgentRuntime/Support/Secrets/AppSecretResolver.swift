import Foundation
import ServiceContracts

enum SecretSourceMode: String, Sendable {
    case keychain
    case dotenv
}

@MainActor
struct AppSecretResolver: Sendable {
    typealias KeychainLoader = @MainActor @Sendable (String) -> String?

    private let environment: [String: String]
    private let currentDirectoryURL: URL
    private let bundleURL: URL
    private let mode: SecretSourceMode
    private let keychainLoader: KeychainLoader

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        bundleURL: URL = Bundle.main.bundleURL,
        keychainLoader: KeychainLoader? = nil
    ) {
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.bundleURL = bundleURL
        self.mode = Self.mode(from: environment, currentDirectoryURL: currentDirectoryURL, bundleURL: bundleURL)
        self.keychainLoader = keychainLoader ?? Self.defaultKeychainLoader
    }

    func resolve(account: String, environmentKeys: [String]) -> String? {
        switch mode {
        case .keychain:
            return keychainValue(for: account)
                ?? environmentValue(for: environmentKeys)
                ?? dotEnvValue(for: environmentKeys)
        case .dotenv:
            return dotEnvValue(for: environmentKeys)
                ?? environmentValue(for: environmentKeys)
        }
    }

    private func keychainValue(for account: String) -> String? {
        guard let value = keychainLoader(account) else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func environmentValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func dotEnvValue(for keys: [String]) -> String? {
        for url in Self.dotEnvSearchURLs(currentDirectoryURL: currentDirectoryURL, bundleURL: bundleURL) {
            guard let values = Self.parseDotEnv(at: url) else {
                continue
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
            let value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }

        return values.isEmpty ? nil : values
    }

    /// Search cwd ancestry, this process's Resources, and the **host app** Resources when
    /// running as an embedded XPC service (`ui.app/.../XPCServices/AgentService.xpc`).
    static func dotEnvSearchURLs(currentDirectoryURL: URL, bundleURL: URL) -> [URL] {
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
        urls.append(bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env"))

        return urls
    }

    /// Walk up from an embedded XPC bundle to `Something.app/Contents/Resources/.env`.
    static func hostAppDotEnvURLs(from bundleURL: URL) -> [URL] {
        var urls: [URL] = []
        var dir = bundleURL.standardizedFileURL

        for _ in 0..<10 {
            if dir.pathExtension == "app" {
                urls.append(dir.appendingPathComponent("Contents/Resources/.env"))
                urls.append(dir.appendingPathComponent("Contents/Resources/ui/.env"))
                break
            }
            if dir.lastPathComponent == "XPCServices" {
                // .../App.app/Contents/XPCServices → .../App.app/Contents/Resources/.env
                let contents = dir.deletingLastPathComponent()
                urls.append(contents.appendingPathComponent("Resources/.env"))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        return urls
    }

    private static func mode(from environment: [String: String], currentDirectoryURL: URL, bundleURL: URL) -> SecretSourceMode {
        if let rawValue = environment["UI_SECRET_MODE"], let mode = SecretSourceMode(rawValue: rawValue) {
            return mode
        }

        if let rawValue = dotEnvValue(
            for: ["UI_SECRET_MODE"],
            currentDirectoryURL: currentDirectoryURL,
            bundleURL: bundleURL
        ), let mode = SecretSourceMode(rawValue: rawValue) {
            return mode
        }

        // Prefer dotenv when a host-app or cwd .env is present (common for debug AgentService).
        for url in dotEnvSearchURLs(currentDirectoryURL: currentDirectoryURL, bundleURL: bundleURL) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let values = parseDotEnv(at: url), values["UI_SECRET_MODE"] == SecretSourceMode.dotenv.rawValue {
                    return .dotenv
                }
                // Explicit file without mode still allows dotenv fallback after keychain in resolve().
                break
            }
        }

        return .keychain
    }

    @MainActor
    private static func defaultKeychainLoader(_ account: String) -> String? {
        // UI stores secrets under the main app id; AgentService's Bundle.main id is different.
        let services = [
            DerrickAppSupport.hostAppBundleIdentifier,
            Bundle.main.bundleIdentifier,
            "ui"
        ].compactMap { $0 }

        var seen = Set<String>()
        for service in services where seen.insert(service).inserted {
            do {
                if let value = try readKeychainSecret(service: service, account: account) {
                    return value
                }
            } catch {
                // try next service id
            }
        }
        return nil
    }

    private static func dotEnvValue(
        for keys: [String],
        currentDirectoryURL: URL,
        bundleURL: URL
    ) -> String? {
        for url in dotEnvSearchURLs(currentDirectoryURL: currentDirectoryURL, bundleURL: bundleURL) {
            guard let values = parseDotEnv(at: url) else { continue }
            for key in keys {
                if let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }
}
