import Foundation
import DockerRunnerXPC
import os.log

/// Implements the XPC protocol. Spawns a docker process and returns stdout/stderr/exitCode.
/// Runs outside the app sandbox — has full access to the Docker daemon socket.
private let serviceLogger = Logger(subsystem: "derrick.ui.DockerRunnerHelper", category: "DockerRunnerService")

actor TimeoutTracker {
    var timedOut = false
    func setTimedOut() {
        timedOut = true
    }
}

actor ProcessRunner {
    func run(launch: ApprovedDockerLaunch, initialLogs: [String]) async -> DockerRunResponse {
        var logs = initialLogs
        logs.append("runProcess called inside ProcessRunner actor.")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executablePath)
        process.arguments = launch.arguments
        process.environment = launch.environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let timeoutSeconds = launch.timeoutSeconds
        let tracker = TimeoutTracker()

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
            if !Task.isCancelled {
                await tracker.setTimedOut()
                process.terminate()
            }
        }

        var launchError: Error? = nil
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
            do {
                try process.run()
                stdinPipe.fileHandleForWriting.write(launch.stdinData)
                stdinPipe.fileHandleForWriting.closeFile()
            } catch {
                launchError = error
                continuation.resume()
            }
        }

        timeoutTask.cancel()

        if let launchError {
            logs.append("Failed to launch process: \(launchError.localizedDescription)")
            return DockerRunResponse(stdout: Data(), stderr: Data(), exitCode: 1, timedOut: false,
                                     launchError: "XPC: failed to launch docker: \(launchError.localizedDescription)", logs: logs)
        }

        let isTimedOut = await tracker.timedOut
        let stdout = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        let exitCode = isTimedOut ? Int32(-1) : process.terminationStatus

        logs.append("Process finished. Timed out: \(isTimedOut). Exit code: \(exitCode). Stdout bytes: \(stdout.count). Stderr bytes: \(stderr.count).")
        if stderr.count > 0 {
            let stderrString = String(data: stderr, encoding: .utf8) ?? "Non-UTF8 stderr"
            logs.append("Stderr output: \(stderrString)")
        }

        return DockerRunResponse(stdout: stdout, stderr: stderr, exitCode: exitCode, timedOut: isTimedOut, launchError: nil, logs: logs)
    }
}

extension NSData: @unchecked @retroactive Sendable {}

final class DockerRunnerService: NSObject, DockerProcessRunnerXPC, @unchecked Sendable {
    private let runner = ProcessRunner()

    nonisolated func runProcess(requestData: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let requestBytes = requestData as Data
        Task {
            var logs: [String] = []
            serviceLogger.log("runProcess invoked. requestBytes=\(requestBytes.count, privacy: .public)")
            HelperLogRelay.shared.log("runProcess invoked. requestBytes=\(requestBytes.count)")
            logs.append("runProcess called.")

            let request: DockerRunRequest
            do {
                request = try JSONDecoder().decode(DockerRunRequest.self, from: requestBytes)
                logs.append("Decoded request to run executable: \(request.executablePath)")
                serviceLogger.log("Decoded request executable=\(request.executablePath, privacy: .public), timeoutSeconds=\(request.timeoutSeconds, privacy: .public), argsCount=\(request.arguments.count, privacy: .public), envCount=\(request.environment.count, privacy: .public)")
                serviceLogger.log("Request arguments=\(request.arguments.joined(separator: " "), privacy: .public)")
                serviceLogger.log("Request environment keys=\(request.environment.keys.sorted().joined(separator: ", "), privacy: .public)")
                HelperLogRelay.shared.log("Decoded request executable=\(request.executablePath), timeoutSeconds=\(request.timeoutSeconds), argsCount=\(request.arguments.count), envCount=\(request.environment.count)")
            } catch {
                logs.append("Failed to decode request: \(error.localizedDescription)")
                serviceLogger.error("Failed to decode request: \(error.localizedDescription, privacy: .public)")
                HelperLogRelay.shared.log("Failed to decode request: \(error.localizedDescription)")
                let response = DockerRunResponse(stdout: Data(), stderr: Data(), exitCode: 1, timedOut: false,
                                                 launchError: "XPC: failed to decode request: \(error.localizedDescription)", logs: logs)
                let replyData = (try? JSONEncoder().encode(response)) ?? Data()
                reply(replyData as NSData)
                return
            }

            switch DockerRunRequestValidator.approve(request) {
            case .failure(let validationError):
                let message = validationError.launchErrorMessage
                logs.append(message)
                serviceLogger.error("Request validation failed: \(message, privacy: .public)")
                HelperLogRelay.shared.log(message)
                let response = DockerRunResponse(
                    stdout: Data(),
                    stderr: Data(),
                    exitCode: 1,
                    timedOut: false,
                    launchError: message,
                    logs: logs
                )
                let replyData = (try? JSONEncoder().encode(response)) ?? Data()
                reply(replyData as NSData)
                return
            case .success(let launch):
                logs.append("Request approved for docker CLI launch.")
                let response = await runner.run(launch: launch, initialLogs: logs)
                let replyData = (try? JSONEncoder().encode(response)) ?? Data()
                reply(replyData as NSData)
            }
        }
    }

    nonisolated func setEgressAllowedDomainSuffixes(
        suffixesJSON: NSData,
        withReply reply: @escaping @Sendable (Bool) -> Void
    ) {
        do {
            let suffixes = try JSONDecoder().decode([String].self, from: suffixesJSON as Data)
            EgressProxyBootstrap.setAllowedDomainSuffixes(suffixes)
            reply(true)
        } catch {
            HelperLogRelay.shared.log(
                "Failed to decode egress allowlist: \(error.localizedDescription)"
            )
            reply(false)
        }
    }

    nonisolated func grantEgressSessionHosts(
        hostsJSON: NSData,
        withReply reply: @escaping @Sendable (Bool) -> Void
    ) {
        do {
            let hosts = try JSONDecoder().decode([String].self, from: hostsJSON as Data)
            EgressProxyBootstrap.grantSessionHosts(hosts)
            reply(true)
        } catch {
            HelperLogRelay.shared.log(
                "Failed to decode egress session hosts: \(error.localizedDescription)"
            )
            reply(false)
        }
    }
}
