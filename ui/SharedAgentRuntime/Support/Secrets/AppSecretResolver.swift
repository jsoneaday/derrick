import Foundation
import Structure

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

    var usesDotenvOnly: Bool { mode == .dotenv }

    func resolve(
        account: String,
        environmentKeys: [String],
        policy: SecretResolutionPolicy = .appDefault
    ) -> String? {
        switch policy {
        case .keychainOnly:
            return keychainValue(for: account)
        case .appDefault:
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
        DotEnvReader.firstValue(
            for: keys,
            environment: environment,
            bundleURL: bundleURL,
            currentDirectoryURL: currentDirectoryURL
        )
    }

    private static func mode(
        from environment: [String: String],
        currentDirectoryURL: URL,
        bundleURL: URL
    ) -> SecretSourceMode {
        switch DotEnvReader.secretSourceMode(
            environment: environment,
            bundleURL: bundleURL,
            currentDirectoryURL: currentDirectoryURL
        ) {
        case .dotenv:
            return .dotenv
        case .keychain:
            return .keychain
        }
    }

    @MainActor
    private static func defaultKeychainLoader(_ account: String) -> String? {
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
}
