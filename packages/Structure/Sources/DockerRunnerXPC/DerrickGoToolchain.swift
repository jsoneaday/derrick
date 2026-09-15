import Foundation

/// Optional host Go toolchain probe (development diagnostics). Guest compile runs in Docker.
public enum DerrickGoToolchain: Sendable {
    public static let minimumVersion = "1.27.1"

    public static func ensureInstalled() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["go", "version"]
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DerrickGoToolchainError.missing
        }
        let text = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let version = parseVersion(text) else {
            throw DerrickGoToolchainError.unparseable(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard versionSatisfies(version, minimum: minimumVersion) else {
            throw DerrickGoToolchainError.tooOld(found: version, required: minimumVersion)
        }
    }

    static func parseVersion(_ text: String) -> String? {
        // go version go1.27.1 darwin/arm64
        for part in text.split(separator: " ") {
            let token = String(part)
            if token.hasPrefix("go"), token.count > 2 {
                return String(token.dropFirst(2))
            }
        }
        return nil
    }

    static func versionSatisfies(_ found: String, minimum: String) -> Bool {
        compareVersions(found, minimum) != .orderedAscending
    }

    private enum Ordering {
        case orderedAscending, orderedSame, orderedDescending
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> Ordering {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }
}

public enum DerrickGoToolchainError: Error, LocalizedError, Sendable {
    case missing
    case unparseable(String)
    case tooOld(found: String, required: String)

    public var errorDescription: String? {
        switch self {
        case .missing:
            return "Go \(DerrickGoToolchain.minimumVersion) or later was expected for diagnostics. Guest compile runs in Docker."
        case .unparseable(let detail):
            return "Could not read the installed Go version (\(detail))."
        case .tooOld(let found, let required):
            return "Go \(required) or later is required to build plugins (found \(found))."
        }
    }
}
