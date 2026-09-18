import Foundation
import Security

/// Host-owned plugin credentials.
///
/// The sandboxed UI and unsandboxed daemon cannot share a process Keychain.
/// Values are written to the app-group container (same place as SQLite) so both
/// processes can read them. Keychain is updated when this process can reach it.
///
/// Each secret has one account name, always:
/// `plugin-secret:<plugin-id>/<field-id>`
///
/// - **plugin-id** is unique per installed plugin. Messaging connectors use
///   `<vendor>-connector-<n>` (`slack-connector-1`, `slack-connector-2`, …).
///   Custom plugins use the normalized plugin name.
/// - **field-id** is the secret slot from the plugin (`bot_token`, `api_key`, …).
///
/// Keychain **service** is the host bundle id. The app-group file uses the same
/// account string with `:` and `/` replaced by `_`.
public enum PluginSecretKeychain: Sendable {
    public static let accountPrefix = "plugin-secret"

    public static func account(pluginID: String, fieldID: String) -> String {
        "\(accountPrefix):\(pluginID)/\(fieldID)"
    }

    public static func load(pluginID: String, fieldID: String) throws -> String? {
        try loadFromKeychain(pluginID: pluginID, fieldID: fieldID)
    }

    /// True when this process can already supply a value (`.env`, app group, or Keychain).
    public static func hasStoredValue(pluginID: String, fieldID: String) -> Bool {
        if PluginSecretDevelopmentSource.resolve(pluginID: pluginID, fieldID: fieldID) != nil {
            return true
        }
        return hasKeychainValue(pluginID: pluginID, fieldID: fieldID)
    }

    public static func hasKeychainValue(pluginID: String, fieldID: String) -> Bool {
        guard let value = try? loadFromKeychain(pluginID: pluginID, fieldID: fieldID) else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func loadFromKeychain(pluginID: String, fieldID: String) throws -> String? {
        if let shared = try? loadSharedStore(pluginID: pluginID, fieldID: fieldID) {
            return shared
        }
        if let local = try? loadProcessKeychain(pluginID: pluginID, fieldID: fieldID) {
            try? saveSharedStore(pluginID: pluginID, fieldID: fieldID, value: local)
            return local
        }
        return nil
    }

    /// Copies process-local Keychain items into the app-group store the daemon reads.
    public static func promoteToSharedGroup(pluginID: String, fields: [PluginSecretDescriptor]) {
        for field in fields {
            if (try? loadSharedStore(pluginID: pluginID, fieldID: field.id)) != nil { continue }
            if let value = try? loadProcessKeychain(pluginID: pluginID, fieldID: field.id) {
                try? saveSharedStore(pluginID: pluginID, fieldID: field.id, value: value)
            }
        }
    }

    public static func save(pluginID: String, fieldID: String, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PluginSecretKeychainError.emptyValue
        }
        try saveSharedStore(pluginID: pluginID, fieldID: fieldID, value: trimmed)
        try? saveProcessKeychain(pluginID: pluginID, fieldID: fieldID, value: trimmed)
    }

    public static func missingIDs(pluginID: String, fields: [PluginSecretDescriptor]) -> [PluginSecretDescriptor] {
        fields.filter { !hasStoredValue(pluginID: pluginID, fieldID: $0.id) }
    }

    /// Fields the daemon cannot read. `.env` in the UI process does not count.
    public static func missingKeychainIDs(
        pluginID: String,
        fields: [PluginSecretDescriptor]
    ) -> [PluginSecretDescriptor] {
        fields.filter { !hasKeychainValue(pluginID: pluginID, fieldID: $0.id) }
    }

    /// Copies stored secrets from a retired plugin id when the destination field is empty.
    public static func migrateStoredFields(
        from sourcePluginID: String,
        to destinationPluginID: String,
        fields: [PluginSecretDescriptor]
    ) {
        guard sourcePluginID != destinationPluginID else { return }
        for field in fields {
            guard !hasKeychainValue(pluginID: destinationPluginID, fieldID: field.id) else { continue }
            let value = (try? loadFromKeychain(pluginID: sourcePluginID, fieldID: field.id))
                ?? PluginSecretDevelopmentSource.resolve(pluginID: sourcePluginID, fieldID: field.id)
            guard let value else { continue }
            try? save(pluginID: destinationPluginID, fieldID: field.id, value: value)
        }
    }

    /// When a declared call-credential field is empty, copy from a sibling alias
    /// (`api_token` → `bot_token`, etc.) so older creates keep working.
    public static func migrateCallCredentialAliases(
        pluginID: String,
        fields: [PluginSecretDescriptor]
    ) {
        let aliases = PluginSecretResolver.callCredentialFieldIDs
        for field in fields {
            guard aliases.contains(field.id),
                  !hasKeychainValue(pluginID: pluginID, fieldID: field.id)
            else { continue }
            for alias in aliases where alias != field.id {
                guard let value = try? loadFromKeychain(pluginID: pluginID, fieldID: alias)
                else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                try? save(pluginID: pluginID, fieldID: field.id, value: trimmed)
                break
            }
        }
    }

    public static func deleteForTesting(pluginID: String, fieldID: String) {
        deleteStoredSecret(pluginID: pluginID, fieldID: fieldID)
    }

    /// Removes every stored secret for a plugin (shared app-group files + Keychain).
    /// Pass `fieldIDs` from the manifest when known; files matching the plugin prefix are
    /// always scanned so leftover fields from older installs are not orphaned.
    public static func deleteAllStoredSecrets(pluginID: String, fieldIDs: [String] = []) {
        let trimmed = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var ids = Set(fieldIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        ids.formUnion(discoveredSharedStoreFieldIDs(pluginID: trimmed))
        // Common slots even when no file / manifest was found.
        for fallback in ["bot_token", "api_token", "api_key", "password", "username", "token"] {
            ids.insert(fallback)
        }
        for fieldID in ids {
            deleteStoredSecret(pluginID: trimmed, fieldID: fieldID)
        }
    }

    /// Best-effort wipe of shared secret files that no longer map to an installed plugin.
    public static func deleteOrphanedSharedSecrets(keepingPluginIDs: Set<String>) {
        guard let directory = try? sharedStoreDirectory() else { return }
        let prefix = "\(accountPrefix)_"
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            guard let pluginID = pluginIDFromSharedStoreFilename(name) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if !keepingPluginIDs.contains(pluginID) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func deleteStoredSecret(pluginID: String, fieldID: String) {
        if let url = try? sharedStoreURL(pluginID: pluginID, fieldID: fieldID) {
            try? FileManager.default.removeItem(at: url)
        }
        let account = account(pluginID: pluginID, fieldID: fieldID)
        for service in services() {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func discoveredSharedStoreFieldIDs(pluginID: String) -> Set<String> {
        guard let directory = try? sharedStoreDirectory() else { return [] }
        // Filename encoding replaces `:` and `/` in the full account string.
        // account(pluginID, "") ends with `/` → encoded prefix ends with `_`.
        let encodedPrefix = account(pluginID: pluginID, fieldID: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        var fields = Set<String>()
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix(encodedPrefix) else { continue }
            let field = String(name.dropFirst(encodedPrefix.count))
            if !field.isEmpty {
                fields.insert(field)
            }
        }
        return fields
    }

    private static func pluginIDFromSharedStoreFilename(_ name: String) -> String? {
        // plugin-secret_<pluginID>_<fieldID>  (':' and '/' already '_')
        let prefix = "\(accountPrefix)_"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = String(name.dropFirst(prefix.count))
        guard let split = rest.lastIndex(of: "_") else { return nil }
        let pluginID = String(rest[..<split])
        return pluginID.isEmpty ? nil : pluginID
    }

    private static func services() -> [String] {
        let services = [
            DerrickAppSupport.hostAppBundleIdentifier,
            Bundle.main.bundleIdentifier
        ].compactMap { $0 }
        var seen = Set<String>()
        return services.filter { seen.insert($0).inserted }
    }

    private static func sharedStoreDirectory() throws -> URL {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DerrickAppSupport.applicationGroupIdentifier
        ) else {
            throw PluginSecretKeychainError.sharedStoreUnavailable
        }
        let directory = root
            .appendingPathComponent("Library/Application Support/plugin-secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func sharedStoreURL(pluginID: String, fieldID: String) throws -> URL {
        let name = account(pluginID: pluginID, fieldID: fieldID)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return try sharedStoreDirectory().appendingPathComponent(name, isDirectory: false)
    }

    private static func loadSharedStore(pluginID: String, fieldID: String) throws -> String? {
        let url = try sharedStoreURL(pluginID: pluginID, fieldID: fieldID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func saveSharedStore(pluginID: String, fieldID: String, value: String) throws {
        let url = try sharedStoreURL(pluginID: pluginID, fieldID: fieldID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try value.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func loadProcessKeychain(pluginID: String, fieldID: String) throws -> String? {
        let account = account(pluginID: pluginID, fieldID: fieldID)
        for service in services() {
            if let value = try read(service: service, account: account) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func saveProcessKeychain(pluginID: String, fieldID: String, value: String) throws {
        try write(
            service: DerrickAppSupport.hostAppBundleIdentifier,
            account: account(pluginID: pluginID, fieldID: fieldID),
            secret: value
        )
    }

    private static func read(service: String, account: String) throws -> String? {
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
            throw PluginSecretKeychainError.readFailed(status)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func write(service: String, account: String, secret: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw PluginSecretKeychainError.encodeFailed
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
            throw PluginSecretKeychainError.writeFailed(status)
        }
    }
}

public enum PluginSecretKeychainError: Error, LocalizedError, Equatable {
    case emptyValue
    case encodeFailed
    case readFailed(OSStatus)
    case writeFailed(OSStatus)
    case sharedStoreUnavailable
    case notStoredForDaemon

    public var errorDescription: String? {
        switch self {
        case .emptyValue:
            return "A plugin secret cannot be empty."
        case .encodeFailed:
            return "Could not encode the plugin secret."
        case .readFailed(let status):
            return "Keychain read failed for a plugin secret (status \(status))."
        case .writeFailed(let status):
            return "Keychain write failed for a plugin secret (status \(status))."
        case .sharedStoreUnavailable:
            return "Could not open the shared connector credential store."
        case .notStoredForDaemon:
            return "Connector credentials could not be stored, so Messaging cannot use them."
        }
    }
}
