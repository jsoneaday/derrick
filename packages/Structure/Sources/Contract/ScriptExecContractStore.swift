import CryptoKit
import Foundation

/// Loads the bundled script_exec protocol JSON.
public enum ScriptExecContractStore: Sendable {
    public static let protocolResource = "script-exec-contract.json"
    public static let fingerprintEntries: [(subdirectory: String, file: String)] = [
        ("schemas", "script-exec-contract.schema.json"),
        ("schemas", "guest-runtime.schema.json"),
        ("schemas", "hop-event.schema.json"),
        ("schemas", "envelope-list.schema.json"),
        ("contracts", "script-exec-contract.json"),
    ]

    public static var fingerprintSources: [String] {
        fingerprintEntries.map { "\($0.subdirectory)/\($0.file)" }
    }

    public static func loadProtocol() throws -> ScriptExecContractDocument {
        try ScriptExecContractIntegrity.validateBundledGraph()
        let data = try resourceData(name: protocolResource, subdirectory: "contracts")
        do {
            return try JSONDecoder().decode(ScriptExecContractDocument.self, from: data)
        } catch {
            throw ScriptExecContractError.invalidJSON(protocolResource)
        }
    }

    public static func loadProtocolText() throws -> String {
        try utf8Text(resourceData(name: protocolResource, subdirectory: "contracts"))
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

    static func resourceData(name: String, subdirectory: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: subdirectory
        ) else {
            throw ScriptExecContractError.missingResource("\(subdirectory)/\(name)")
        }
        return try Data(contentsOf: url)
    }

    private static func utf8Text(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ScriptExecContractError.invalidJSON(protocolResource)
        }
        return text
    }
}
