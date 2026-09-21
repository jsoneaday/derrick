import CryptoKit
import Foundation

/// Loads the bundled connector protocol JSON.
public enum ConnectorContractStore: Sendable {
    public static let protocolResource = "connector-contract.json"
    public static let fingerprintEntries: [(subdirectory: String, file: String)] = [
        ("schemas", "connector-contract.schema.json"),
        ("schemas", "connector-params.schema.json"),
        ("schemas", "connector-result-emit.schema.json"),
        ("contracts", "connector-contract.json"),
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

    public static func loadHostContract(_ name: String) throws -> Data {
        try resourceData(name: "\(name).json", subdirectory: "contracts/host")
    }

    private static func utf8Text(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectorContractError.invalidJSON(protocolResource)
        }
        return text
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

    public static func urlNeedles(forCallIDs ids: [String]) -> [String] {
        ids.filter { !$0.isEmpty }
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
