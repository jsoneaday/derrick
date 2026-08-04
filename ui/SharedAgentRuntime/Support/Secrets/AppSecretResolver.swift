import Foundation

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
        print("AppSecretResolver: resolving account=\(account)")
        switch mode {
        case .keychain:
            let val = keychainValue(for: account)
                ?? environmentValue(for: environmentKeys)
                ?? dotEnvValue(for: environmentKeys)
            print("AppSecretResolver (keychain mode): found=\(val != nil)")
            return val
        case .dotenv:
            let val = dotEnvValue(for: environmentKeys)
                ?? environmentValue(for: environmentKeys)
            print("AppSecretResolver (dotenv mode): found=\(val != nil)")
            return val
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
        for url in dotEnvSearchURLs() {
            guard let values = parseDotEnv(at: url) else {
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

    private func parseDotEnv(at url: URL) -> [String: String]? {
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

    private func dotEnvSearchURLs() -> [URL] {
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

        urls.append(bundleURL.deletingLastPathComponent().appendingPathComponent(".env"))
        urls.append(bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env"))

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

        return .keychain
    }

    @MainActor
    private static func defaultKeychainLoader(_ account: String) -> String? {
        do {
            let service = Bundle.main.bundleIdentifier ?? "ui"
            return try readKeychainSecret(service: service, account: account)
        } catch {
            print("AppSecretResolver keychain lookup failed for account=\(account): \(error.localizedDescription)")
            return nil
        }
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
            urls.append(candidate.appendingPathComponent("ui/ui/Resources/.env"))
            candidate.deleteLastPathComponent()
        }

        urls.append(bundleURL.deletingLastPathComponent().appendingPathComponent(".env"))
        urls.append(bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env"))

        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else {
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
                if let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
        }

        return nil
    }
}
