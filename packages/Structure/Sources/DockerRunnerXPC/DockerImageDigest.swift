import Foundation

/// SHA-256 image ID from `docker image inspect --format '{{.Id}}'`.
public struct DockerImageDigest: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = Self.normalize(rawValue)
    }

    public init?(hexDigest: String) {
        let normalized = Self.normalize(hexDigest)
        guard Self.isValid(normalized) else { return nil }
        rawValue = normalized
    }

    public static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("sha256:") {
            return trimmed
        }
        if trimmed.count == 64 {
            return "sha256:\(trimmed)"
        }
        return trimmed
    }

    public static func isValid(_ value: String) -> Bool {
        let hex = value.hasPrefix("sha256:") ? String(value.dropFirst(7)) : value
        guard hex.count == 64 else { return false }
        return hex.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    }
}

public enum DockerImageDigestError: Error, LocalizedError, Sendable, Equatable {
    case imageMissing(String)
    case digestMismatch(tag: String, expected: DockerImageDigest, actual: DockerImageDigest)

    public var errorDescription: String? {
        switch self {
        case .imageMissing(let tag):
            return "The worker image \(tag) is not installed."
        case .digestMismatch(let tag, _, _):
            return "The worker image \(tag) does not match the version shipped with Derrick. Rebuild or reinstall product images."
        }
    }
}
