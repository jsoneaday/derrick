import Foundation
import Security

enum SecretStoreError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain error: \(status)"
        case .invalidData:
            return "Keychain returned invalid data."
        }
    }
}

struct SecretStore {
    private let service: String
    private let account: String

    init(service: String = Bundle.main.bundleIdentifier ?? "ui", account: String) {
        self.service = service
        self.account = account
    }

    func load() throws -> String? {
        print("SecretStore load() called for account: \(account)")
        let result = try readKeychainSecret(service: service, account: account)
        print("SecretStore load() result: found=\(result != nil)")
        return result
    }

    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }

        if status != errSecItemNotFound {
            throw SecretStoreError.unexpectedStatus(status)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecretStoreError.unexpectedStatus(addStatus)
        }
    }
}

func readKeychainSecret(service: String, account: String) throws -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
        guard let data = item as? Data else {
            print("SecretStore load() failed: invalid keychain data for account \(account)")
            throw SecretStoreError.invalidData
        }

        guard let value = String(data: data, encoding: .utf8) else {
            print("SecretStore load() failed: unable to decode keychain data for account \(account)")
            throw SecretStoreError.invalidData
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    case errSecItemNotFound:
        return nil
    default:
        print("SecretStore load() failed: unexpected status \(status) for account \(account)")
        throw SecretStoreError.unexpectedStatus(status)
    }
}
