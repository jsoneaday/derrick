import Foundation

/// Locates the Derrick source / monorepo root (directory containing `docker/`).
public enum DerrickRepositoryRoot: Sendable {
    public static func locate() -> URL? {
        var candidates: [URL] = []
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource)
        }
        candidates.append(Bundle.main.bundleURL)
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<20 {
            candidates.append(dir)
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        var seen = Set<String>()
        for candidate in candidates {
            let root = candidate.standardizedFileURL
            let path = root.path
            guard seen.insert(path).inserted else { continue }
            let dockerfile = root
                .appendingPathComponent("docker/web-crawler/Dockerfile")
            if FileManager.default.fileExists(atPath: dockerfile.path) {
                return root
            }
        }
        return nil
    }
}
