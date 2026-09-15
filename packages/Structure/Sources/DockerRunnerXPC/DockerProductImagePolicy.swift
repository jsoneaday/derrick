import Foundation

/// Trusted product Docker images built from in-repo Dockerfiles (not pulled from a registry).
public enum DockerProductImagePolicy: Sendable {
    public static let workerImage = DockerWorkerRuntime.image
    public static let workerDockerfileRelativePath = DockerWorkerRuntime.dockerfileRelativePath
    public static let workerBuildContextRelativePath = DockerWorkerRuntime.buildContextRelativePath

    /// Legacy crawler tag — retained for orphan sweeps only.
    public static let webCrawlerImage = "derrick-web-crawler:swift-6.4-v1"
    public static let webCrawlerDockerfileRelativePath = "docker/web-crawler/Dockerfile"
    public static let webCrawlerBuildContextRelativePath = "packages"

    public static let allowedBuildImageTags: Set<String> = [
        workerImage,
    ]

    public static func workerBuildContext(repoRoot: URL) -> URL {
        repoRoot.standardizedFileURL
    }

    public static func isAllowedWorkerBuild(
        dockerfilePath: String,
        imageTag: String,
        contextPath: String
    ) -> Bool {
        guard imageTag == workerImage else { return false }
        let dockerfileURL = URL(fileURLWithPath: dockerfilePath).standardizedFileURL
        let contextURL = URL(fileURLWithPath: contextPath).standardizedFileURL
        let repoRoot = contextURL.standardizedFileURL
        let expectedDockerfile = repoRoot
            .appendingPathComponent(workerDockerfileRelativePath)
            .standardizedFileURL
        return dockerfileURL.path == expectedDockerfile.path
    }

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
