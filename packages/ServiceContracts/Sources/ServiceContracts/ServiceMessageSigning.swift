import Foundation
import CryptoKit

/// v1 HMAC-SHA256 over a stable canonical string (plan: app-group shared key).
public enum ServiceMessageSigning: Sendable {
    /// Stable canonical form. Intentionally omits `createdAt` — JSON date round-trips
    /// (ISO-8601) are not bit-stable and previously caused intermittent `invalidSignature`
    /// across UI ↔ XPC processes. Replay uniqueness comes from `id` + payload.
    public static func canonicalBytes(for message: ServiceMessage) -> Data {
        let payloadB64 = message.payloadJSON.base64EncodedString()
        let corr = message.correlationId ?? ""
        let principal: String
        switch message.principal {
        case .ui: principal = "ui"
        case .system: principal = "system"
        case .agent(let s, let a): principal = "agent:\(s):\(a)"
        case .job(let j): principal = "job:\(j)"
        case .webhook(let s): principal = "webhook:\(s)"
        case .plugin(let id, let version): principal = "plugin:\(id):\(version)"
        }
        let line = [
            message.id.uuidString,
            message.from.rawValue,
            message.to.rawValue,
            message.type.rawValue,
            principal,
            corr,
            payloadB64
        ].joined(separator: "|")
        return Data(line.utf8)
    }

    public static func sign(_ message: inout ServiceMessage, key: SymmetricKey) {
        let data = canonicalBytes(for: message)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        message.signature = Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ message: ServiceMessage, key: SymmetricKey) -> Bool {
        guard let signature = message.signature, !signature.isEmpty else { return false }
        let data = canonicalBytes(for: message)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        let expected = Data(mac).map { String(format: "%02x", $0) }.joined()
        // Constant-time compare on equal-length hex strings.
        guard signature.utf8.count == expected.utf8.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(signature.utf8, expected.utf8) {
            diff |= a ^ b
        }
        return diff == 0
    }

    /// Dev-only fixed seed (tests). Production uses `MessagesSecretKey`.
    public static func developmentKey(seed: String = "derrick.service.v1") -> SymmetricKey {
        MessagesSecretKey.keyFromSecretString(seed)
    }
}
