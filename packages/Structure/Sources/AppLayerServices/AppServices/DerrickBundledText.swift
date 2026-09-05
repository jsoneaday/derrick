import Foundation
import os

/// Loads prompt, SDK, and guest runtime files from SharedAgentRuntime Resources.
///
/// Search order: an explicit root, the process bundle, ancestor `.app` Resources
/// (LoginItem / XPC → host app), then the source tree (SPM tests).
public enum DerrickBundledText: Sendable {
    private static let extraRoots = OSAllocatedUnfairLock(initialState: [URL]())

    public static func registerSearchRoot(_ url: URL) {
        extraRoots.withLock { roots in
            if !roots.contains(url) {
                roots.append(url)
            }
        }
    }

    public static func load(_ relativePath: String, from resourceRoot: URL? = nil) throws -> String {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else {
            throw DerrickBundledTextError.missing(relativePath: relativePath, searched: [])
        }
        var seen = Set<String>()
        // An explicit root is a test/override: do not fall through to the app bundle or source tree.
        let urls = resourceRoot == nil
            ? candidateURLs(relativePath: trimmed, resourceRoot: nil)
            : explicitRootURLs(relativePath: trimmed, resourceRoot: resourceRoot!)
        for url in urls {
            let path = url.path
            guard seen.insert(path).inserted else { continue }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw DerrickBundledTextError.missing(
            relativePath: trimmed,
            searched: Array(seen)
        )
    }

    public static func mustLoad(_ relativePath: String, from resourceRoot: URL? = nil) -> String {
        do {
            return try load(relativePath, from: resourceRoot)
        } catch {
            preconditionFailure("Missing bundled text \(relativePath): \(error.localizedDescription)")
        }
    }

    public static func formatCodeForModel(
        _ source: String,
        heading: String,
        language: String = "swift"
    ) -> String {
        """
        # \(heading)

        ```\(language)
        \(source)
        ```
        """
    }

    /// Directory that contains `conversation_rag_instructions.md` when it can be found.
    public static func resolvedResourceRoot() -> URL? {
        for root in searchRoots(explicit: nil) {
            let probe = root.appendingPathComponent("conversation_rag_instructions.md")
            if FileManager.default.fileExists(atPath: probe.path) {
                return root
            }
            let nested = root
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("conversation_rag_instructions.md")
            if FileManager.default.fileExists(atPath: nested.path) {
                return root.appendingPathComponent("Resources", isDirectory: true)
            }
        }
        return nil
    }

    private static func explicitRootURLs(relativePath: String, resourceRoot: URL) -> [URL] {
        let fileName = (relativePath as NSString).lastPathComponent
        let prefixes = [
            "",
            "Resources/",
            "Resources/Resources/",
            "Contents/Resources/",
            "Contents/Resources/Resources/",
        ]
        var urls: [URL] = []
        for prefix in prefixes {
            urls.append(resourceRoot.appendingPathComponent(prefix + relativePath))
            urls.append(resourceRoot.appendingPathComponent(prefix + "guest/\(fileName)"))
        }
        return urls
    }

    private static func candidateURLs(relativePath: String, resourceRoot: URL?) -> [URL] {
        let fileName = (relativePath as NSString).lastPathComponent
        var urls: [URL] = []
        for root in searchRoots(explicit: resourceRoot) {
            urls.append(contentsOf: explicitRootURLs(relativePath: relativePath, resourceRoot: root))
            if fileName != relativePath {
                urls.append(root.appendingPathComponent(fileName))
            }
        }
        return urls
    }

    private static func searchRoots(explicit: URL?) -> [URL] {
        var roots: [URL] = extraRoots.withLock { $0 }
        if let explicit {
            roots.append(explicit)
        }
        let main = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        roots.append(main)
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            roots.append(bundle.bundleURL)
            if let resourceURL = bundle.resourceURL {
                roots.append(resourceURL)
            }
        }
        // SPM resource bundle for Plugin (`Package.swift` copies SharedAgentRuntime Resources).
        let pluginBundleNames = ["Plugin_Plugin.bundle", "Plugin.bundle"]
        let bundleAnchors = [
            Bundle.main.bundleURL,
            Bundle.main.resourceURL,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true),
        ].compactMap { $0 }
        for anchor in bundleAnchors {
            for name in pluginBundleNames {
                roots.append(anchor.appendingPathComponent(name, isDirectory: true))
            }
        }
        var dir = Bundle.main.bundleURL.standardizedFileURL
        for _ in 0..<12 {
            if dir.pathExtension == "app" || dir.pathExtension == "xpc" {
                let res = dir.appendingPathComponent("Contents/Resources", isDirectory: true)
                roots.append(res)
                roots.append(res.appendingPathComponent("Plugin_Plugin.bundle", isDirectory: true))
                roots.append(
                    res.appendingPathComponent("Plugin_Plugin.bundle/Contents/Resources", isDirectory: true)
                )
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        if let source = sourceTreeResources() {
            roots.append(source)
        }
        return roots
    }

    /// Walks from this file to `ui/SharedAgentRuntime/Resources` in a source checkout.
    private static func sourceTreeResources() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<16 {
            let candidate = dir
                .appendingPathComponent("ui", isDirectory: true)
                .appendingPathComponent("SharedAgentRuntime", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
            let probe = candidate.appendingPathComponent("conversation_rag_instructions.md")
            if FileManager.default.fileExists(atPath: probe.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}

public enum DerrickBundledTextError: Error, Equatable, LocalizedError {
    case missing(relativePath: String, searched: [String])

    public var errorDescription: String? {
        switch self {
        case .missing(let relativePath, let searched):
            let list = searched.prefix(8).joined(separator: ", ")
            return "Missing bundled text \(relativePath). Searched: \(list)"
        }
    }
}
