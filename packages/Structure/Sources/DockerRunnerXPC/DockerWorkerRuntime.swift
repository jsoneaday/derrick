import Foundation

/// Unified Go worker image shared by crawl, extract, and plugin guest execution.
public enum DockerWorkerRuntime: Sendable {
    public static let image = "derrick-worker:go-v1"
    public static let dockerfileRelativePath = "docker/worker/Dockerfile"
    public static let buildContextRelativePath = "."

    public static let crawlerBinary = "/usr/local/bin/derrick-web-crawler"
    public static let extractorBinary = "/usr/local/bin/derrick-file-extractor"
    public static let guestBinaryPath = "/tmp/guest"
    public static let guestSourcePath = "/tmp/plugin.go"
    public static let goBinaryPath = "/usr/local/go/bin/go"

    /// Allowed `docker exec … sh -c` payloads for guest source I/O and in-container compile.
    public static let guestWriteSourceShell = "cat > /tmp/plugin.go"
    public static let guestCompileShell =
        "cd /tmp && /usr/local/go/bin/go build -trimpath -ldflags=-s -w -o guest plugin.go && chmod +x guest"
    public static let guestReadBinaryShell = "cat /tmp/guest"

    public static let pinnedDigest = DockerProductImageDigests.worker
}
