import Foundation

/// Tight bind-mount policy for file extractor jobs.
///
/// Only these mounts are allowed:
/// - `{any prefix}/file-jobs/{uuid}/in:/data/in:ro`
/// - `{any prefix}/file-jobs/{uuid}/out:/data/out` or `:rw`
public enum FileJobBindMountPolicy: Sendable {
    public static let guestInputPath = "/data/in"
    public static let guestOutputPath = "/data/out"
    public static let jobsFolderName = "file-jobs"

    public static func isAllowedVolumeSpec(_ spec: String) -> Bool {
        guard let parsed = parse(spec) else { return false }
        return isAllowed(hostPath: parsed.host, guestPath: parsed.guest, mode: parsed.mode)
    }

    public static func isAllowed(hostPath: String, guestPath: String, mode: String?) -> Bool {
        let guest = URL(fileURLWithPath: guestPath).standardizedFileURL.path
        let host = URL(fileURLWithPath: hostPath).standardizedFileURL.path
        guard host.hasPrefix("/"), !host.contains("..") else { return false }
        let hostParts = host.split(separator: "/").map(String.init)
        guard hostParts.count >= 4 else { return false }
        let leaf = hostParts[hostParts.count - 1]
        let jobID = hostParts[hostParts.count - 2]
        let jobs = hostParts[hostParts.count - 3]
        guard jobs == jobsFolderName, isUUID(jobID) else { return false }
        let modeValue = (mode ?? "rw").lowercased()
        if guest == guestInputPath {
            return leaf == "in" && modeValue == "ro"
        }
        if guest == guestOutputPath {
            return leaf == "out" && (modeValue == "rw" || modeValue == "")
        }
        return false
    }

    public static func parse(_ spec: String) -> (host: String, guest: String, mode: String?)? {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let host = parts[0]
        let guest = parts[1]
        let mode = parts.count == 3 ? parts[2] : nil
        guard host.hasPrefix("/"), guest.hasPrefix("/") else { return nil }
        return (host, guest, mode)
    }

    public static func isUUID(_ value: String) -> Bool {
        let parts = value.split(separator: "-").map(String.init)
        guard parts.count == 5 else { return false }
        let lengths = [8, 4, 4, 4, 12]
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        for (part, length) in zip(parts, lengths) {
            guard part.count == length, part.unicodeScalars.allSatisfy({ hex.contains($0) }) else {
                return false
            }
        }
        return true
    }
}
