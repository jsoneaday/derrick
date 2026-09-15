import Foundation

/// Unified Go worker image shared by crawl, search, extract, and plugin guest execution.
public enum DockerWorkerRuntime: Sendable {
    public static let image = "derrick-worker:go-v1"
    public static let dockerfileRelativePath = "docker/worker/Dockerfile"
    public static let buildContextRelativePath = "."

    public static let crawlerBinary = "/usr/local/bin/derrick-web-crawler"
    public static let searchBinary = "/usr/local/bin/derrick-web-search"
    public static let extractorBinary = "/usr/local/bin/derrick-file-extractor"
    /// DuckDuckGo hosts the search worker is allowed to reach through the egress proxy.
    public static let searchHosts = [
        "html.duckduckgo.com",
        "lite.duckduckgo.com",
        "duckduckgo.com",
    ]
    /// Binaries that must exist in the unified worker image.
    public static let requiredBinaries: [String] = [
        crawlerBinary,
        searchBinary,
        extractorBinary,
    ]

    public static let guestBinaryPath = "/tmp/guest"
    public static let guestSourcePath = "/tmp/plugin.go"
    public static let goBinaryPath = "/usr/local/go/bin/go"

    /// Allowed `docker exec … sh -c` payloads for guest source I/O and in-container compile.
    public static let guestWriteSourceShell = "cat > /tmp/plugin.go"
    public static let guestCompileShell =
        "cd /tmp && /usr/local/go/bin/go build -trimpath -ldflags=\"-s -w\" -o guest plugin.go && chmod +x guest"
    public static let guestReadBinaryShell = "cat /tmp/guest"

    /// Recorded image id from a known-good build. Runtime readiness uses the
    /// binaries label, not this pin — Docker assigns a new id on every local build.
    public static let recordedDigest = DockerProductImageDigests.worker
    /// Legacy alias. Do not use as a runtime gate.
    public static let pinnedDigest = recordedDigest

    /// OCI label written by `docker/worker/Dockerfile`; used to detect stale local images.
    public static let binariesLabelKey = "derrick.worker.binaries"
    public static let binariesLabelValue = "crawler,extractor,search"
    /// `docker image inspect --format` template for `binariesLabelKey`.
    public static let binariesInspectFormat =
        "{{index .Config.Labels \"\(binariesLabelKey)\"}}"
}
