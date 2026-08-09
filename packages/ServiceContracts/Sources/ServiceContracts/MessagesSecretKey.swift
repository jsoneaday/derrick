import Foundation
import CryptoKit
import Security

/// Resolves the shared HMAC secret for `ServiceMessage` signing.
///
/// - **Debug** (`IS_DEBUG=true` in env or `.env`): require `MESSAGES_SECRET_KEY` (no Keychain).
/// - **Release** (`IS_DEBUG` not true): Keychain get-or-create random 32-byte secret.
public enum MessagesSecretKey: Sendable {
    public static let environmentKeyName = "MESSAGES_SECRET_KEY"
    public static let debugFlagName = "IS_DEBUG"
    /// Keychain account; service is host app id first so UI + XPC share the item when possible.
    public static let keychainAccount = "messages-secret-key"
    public static let keychainServiceFallback = "derrick.ui.messages"

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var key: SymmetricKey?
    }

    private static let cache = Cache()

    /// Cached SymmetricKey for HMAC (derived via SHA-256 of the secret material).
    public static func symmetricKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) throws -> SymmetricKey {
        cache.lock.lock()
        if let existing = cache.key {
            cache.lock.unlock()
            return existing
        }
        cache.lock.unlock()

        let secret = try resolveSecretString(
            environment: environment,
            bundleURL: bundleURL,
            currentDirectoryURL: currentDirectoryURL
        )
        let key = keyFromSecretString(secret)

        cache.lock.lock()
        cache.key = key
        cache.lock.unlock()
        return key
    }

    /// Clear cache (tests).
    public static func resetCacheForTesting() {
        cache.lock.lock()
        cache.key = nil
        cache.lock.unlock()
    }

    public static func isDebugMode(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> Bool {
        if let value = environment[debugFlagName]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            return value == "true"
        }
        if let value = DotEnvReader.value(
            for: debugFlagName,
            environment: environment,
            bundleURL: bundleURL,
            currentDirectoryURL: currentDirectoryURL
        )?.lowercased() {
            return value == "true"
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    public static func resolveSecretString(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) throws -> String {
        if isDebugMode(environment: environment, bundleURL: bundleURL, currentDirectoryURL: currentDirectoryURL) {
            if let env = environment[environmentKeyName]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
                return env
            }
            if let fromFile = DotEnvReader.value(
                for: environmentKeyName,
                environment: environment,
                bundleURL: bundleURL,
                currentDirectoryURL: currentDirectoryURL
            ), !fromFile.isEmpty {
                return fromFile
            }
            throw MessagesSecretKeyError.missingDebugSecret
        }

        // Release: Keychain get-or-create.
        if let existing = readKeychainSecret() {
            return existing
        }
        let generated = randomSecretString()
        try writeKeychainSecret(generated)
        return generated
    }

    public static func keyFromSecretString(_ secret: String) -> SymmetricKey {
        let digest = SHA256.hash(data: Data(secret.utf8))
        return SymmetricKey(data: Data(digest))
    }

    // MARK: - Keychain

    private static func keychainServices() -> [String] {
        let services = [
            DerrickAppSupport.hostAppBundleIdentifier,
            keychainServiceFallback,
            Bundle.main.bundleIdentifier
        ].compactMap { $0 }
        var seen = Set<String>()
        return services.filter { seen.insert($0).inserted }
    }

    private static func readKeychainSecret() -> String? {
        for service in keychainServices() {
            if let value = try? readKeychain(service: service, account: keychainAccount) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func writeKeychainSecret(_ secret: String) throws {
        // Prefer host app service name so sibling XPC processes can find it by the same id.
        let service = DerrickAppSupport.hostAppBundleIdentifier
        try writeKeychain(service: service, account: keychainAccount, secret: secret)
    }

    private static func randomSecretString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fallback: CryptoKit random via UUID entropy (still better than fixed seed).
            bytes = Array(UUID().uuidString.utf8.prefix(32))
            while bytes.count < 32 { bytes.append(UInt8.random(in: 0...255)) }
        }
        return Data(bytes).base64EncodedString()
    }

    private static func readKeychain(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MessagesSecretKeyError.keychainReadFailed(status)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(service: String, account: String, secret: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw MessagesSecretKeyError.encodeFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MessagesSecretKeyError.keychainWriteFailed(status)
        }
    }
}

public enum MessagesSecretKeyError: Error, LocalizedError, Equatable {
    case missingDebugSecret
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case encodeFailed

    public var errorDescription: String? {
        switch self {
        case .missingDebugSecret:
            return "IS_DEBUG is true but \(MessagesSecretKey.environmentKeyName) is missing from environment/.env."
        case .keychainReadFailed(let s):
            return "Keychain read failed for messages secret (status \(s))."
        case .keychainWriteFailed(let s):
            return "Keychain write failed for messages secret (status \(s))."
        case .encodeFailed:
            return "Failed to encode messages secret."
        }
    }
}

/// Minimal .env reader shared by message secret resolution (no UI dependency).
enum DotEnvReader {
    static func value(
        for key: String,
        environment: [String: String],
        bundleURL: URL,
        currentDirectoryURL: URL
    ) -> String? {
        for url in searchURLs(bundleURL: bundleURL, currentDirectoryURL: currentDirectoryURL) {
            guard let values = parse(at: url) else { continue }
            if let v = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
        }
        return nil
    }

    static func searchURLs(bundleURL: URL, currentDirectoryURL: URL) -> [URL] {
        var urls: [URL] = []
        var candidate = currentDirectoryURL
        for _ in 0..<12 {
            urls.append(candidate.appendingPathComponent(".env"))
            urls.append(candidate.appendingPathComponent("ui/.env"))
            urls.append(candidate.appendingPathComponent("ui/ui/Resources/.env"))
            urls.append(candidate.appendingPathComponent("Resources/.env"))
            candidate.deleteLastPathComponent()
        }
        if let resourceURL = Bundle(url: bundleURL)?.resourceURL {
            urls.append(resourceURL.appendingPathComponent(".env"))
            urls.append(resourceURL.appendingPathComponent("Resources/.env"))
        }
        // Embedded bundles → host app Resources (.env, secrets). Walk every `.app` ancestor
        // (LoginItems/JobKeepAlive.app is nested under ui.app — do not stop at the inner app).
        var dir = bundleURL.standardizedFileURL
        for _ in 0..<10 {
            if dir.pathExtension == "app" {
                urls.append(dir.appendingPathComponent("Contents/Resources/.env"))
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

    static func parse(at url: URL) -> [String: String]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        var values: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let k = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            values[k] = v
        }
        return values.isEmpty ? nil : values
    }
}
