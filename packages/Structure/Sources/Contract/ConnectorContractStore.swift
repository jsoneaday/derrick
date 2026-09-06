import CryptoKit
import Foundation

/// Loads the bundled connector protocol JSON and vendor profiles.
public enum ConnectorContractStore: Sendable {
    public static let protocolResource = "connector-contract.json"
    public static let fingerprintEntries: [(subdirectory: String, file: String)] = [
        ("schemas", "connector-contract.schema.json"),
        ("schemas", "connector-params.schema.json"),
        ("schemas", "connector-result-emit.schema.json"),
        ("schemas", "connector-vendor.schema.json"),
        ("contracts", "connector-contract.json"),
        ("contracts/vendors", "slack.json"),
    ]

    public static var fingerprintSources: [String] {
        fingerprintEntries.map { "\($0.subdirectory)/\($0.file)" }
    }

    public static func loadProtocol() throws -> ConnectorProtocolDocument {
        try ConnectorContractIntegrity.validateBundledGraph()
        let data = try resourceData(name: "connector-contract.json", subdirectory: "contracts")
        do {
            return try JSONDecoder().decode(ConnectorProtocolDocument.self, from: data)
        } catch {
            throw ConnectorContractError.invalidJSON(protocolResource)
        }
    }

    public static func loadProtocolText() throws -> String {
        try utf8Text(resourceData(name: "connector-contract.json", subdirectory: "contracts"))
    }

    public static func loadVendorText(_ vendor: String) throws -> String? {
        let name = vendor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, name != "custom" else { return nil }
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "contracts/vendors"
        ) else {
            return nil
        }
        return try utf8Text(Data(contentsOf: url))
    }

    private static func utf8Text(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectorContractError.invalidJSON(protocolResource)
        }
        return text
    }

    public static func loadVendor(_ vendor: String) throws -> ConnectorVendorProfile? {
        let name = vendor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, name != "custom" else { return nil }
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "contracts/vendors"
        ) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(ConnectorVendorProfile.self, from: data)
        } catch {
            throw ConnectorContractError.invalidJSON("vendors/\(name).json")
        }
    }

    public static func computeFingerprint() throws -> String {
        var joined = Data()
        for entry in fingerprintEntries {
            let relative = "\(entry.subdirectory)/\(entry.file)"
            let data = try resourceData(name: entry.file, subdirectory: entry.subdirectory)
            joined.append(Data(relative.utf8))
            joined.append(0)
            joined.append(data)
            joined.append(0)
        }
        let digest = SHA256.hash(data: joined)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func urlNeedles(
        forCallIDs ids: [String],
        vendor: ConnectorVendorProfile?
    ) -> [String] {
        ids.flatMap { id -> [String] in
            if let call = vendor?.calls[id] {
                return [call.method, call.url].filter { !$0.isEmpty }
            }
            return [id]
        }
    }

    public static func vendorName(fromUserGoal goal: String?) -> String? {
        guard let goal else { return nil }
        let lowered = goal.lowercased()
        if lowered.contains("slack") { return "slack" }
        if lowered.contains("telegram") { return "telegram" }
        if lowered.contains("whatsapp") { return "whatsapp" }
        if lowered.contains("discord") { return "discord" }
        return nil
    }

    static func resourceData(name: String, subdirectory: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: subdirectory
        ) else {
            throw ConnectorContractError.missingResource("\(subdirectory)/\(name)")
        }
        return try Data(contentsOf: url)
    }
}
