import Foundation
import Structure

public enum DirectShellDocker {
    public static func executor() -> DockerCLIExecutor {
        { arguments, stdin, timeoutSeconds in
            let dockerPath = resolveDockerPath()
            return try await run(
                executable: dockerPath,
                arguments: arguments,
                stdin: stdin,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    private static func resolveDockerPath() -> String {
        for candidate in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "docker"
    }

    private static func run(
        executable: String,
        arguments: [String],
        stdin: Data,
        timeoutSeconds: Int
    ) async throws -> DockerCLIResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: DockerCLIResult(
                        exitCode: proc.terminationStatus,
                        stdout: stdout,
                        stderr: stderr
                    )
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            if !stdin.isEmpty {
                stdinPipe.fileHandleForWriting.write(stdin)
            }
            stdinPipe.fileHandleForWriting.closeFile()

            let timeoutNs = UInt64(max(1, timeoutSeconds)) * 1_000_000_000
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(timeoutNs))) {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}
