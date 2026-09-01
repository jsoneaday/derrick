import Foundation
import Security

/// Host-owned plugin credentials. Service is the host app id so UI and XPC share items.
public enum PluginSecretKeychain: Sendable {
    public static func account(pluginID: String, fieldID: String) -> String {
        "plugin-secret:\(pluginID)/\(fieldID)"
    }

    public static func load(pluginID: String, fieldID: String) throws -> String? {
        try loadFromKeychain(pluginID: pluginID, fieldID: fieldID)
    }

    public static func hasStoredValue(pluginID: String, fieldID: String) -> Bool {
        guard let value = try? loadFromKeychain(pluginID: pluginID, fieldID: fieldID) else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func loadFromKeychain(pluginID: String, fieldID: String) throws -> String? {
        let account = account(pluginID: pluginID, fieldID: fieldID)
        for service in services() {
            if let value = try read(service: service, account: account) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    public static func save(pluginID: String, fieldID: String, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PluginSecretKeychainError.emptyValue
        }
        try write(
            service: DerrickAppSupport.hostAppBundleIdentifier,
            account: account(pluginID: pluginID, fieldID: fieldID),
            secret: trimmed
        )
    }

    public static func missingIDs(pluginID: String, fields: [PluginSecretDescriptor]) -> [PluginSecretDescriptor] {
        fields.filter { !hasStoredValue(pluginID: pluginID, fieldID: $0.id) }
    }

    public static func deleteForTesting(pluginID: String, fieldID: String) {
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

    private static func services() -> [String] {
        let services = [
            DerrickAppSupport.hostAppBundleIdentifier,
            Bundle.main.bundleIdentifier
        ].compactMap { $0 }
        var seen = Set<String>()
        return services.filter { seen.insert($0).inserted }
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
        }
    }
}
