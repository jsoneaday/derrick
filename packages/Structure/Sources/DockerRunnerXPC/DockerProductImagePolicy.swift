import Foundation

/// Trusted product images built from in-repo Dockerfiles (not pulled from a registry).
public enum DockerProductImagePolicy: Sendable {
    public static let webCrawlerImage = "derrick-web-crawler:swift-6.4-v1"
    public static let webCrawlerDockerfileRelativePath = "docker/web-crawler/Dockerfile"
    /// Sibling Swift packages only — not the whole git checkout.
    public static let webCrawlerBuildContextRelativePath = "packages"

    public static let allowedBuildImageTags: Set<String> = [
        webCrawlerImage,
    ]

    public static func webCrawlerBuildContext(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(webCrawlerBuildContextRelativePath).standardizedFileURL
    }

    public static func isAllowedWebCrawlerBuild(
        dockerfilePath: String,
        imageTag: String,
        contextPath: String
    ) -> Bool {
        guard imageTag == webCrawlerImage else { return false }
        let dockerfileURL = URL(fileURLWithPath: dockerfilePath).standardizedFileURL
        let contextURL = URL(fileURLWithPath: contextPath).standardizedFileURL
        guard contextURL.lastPathComponent == webCrawlerBuildContextRelativePath else {
            return false
        }
        let repoRoot = contextURL.deletingLastPathComponent()
        let expectedDockerfile = repoRoot
            .appendingPathComponent(webCrawlerDockerfileRelativePath)
            .standardizedFileURL
        return dockerfileURL.path == expectedDockerfile.path
    }
}
