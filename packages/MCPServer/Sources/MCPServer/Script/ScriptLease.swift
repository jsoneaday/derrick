import Foundation
import Plugin

public struct ScriptHopResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var envelopes: [PluginEnvelope]
}

/// Two-phase lease helpers (install → cut net → handle hops).
public enum ScriptLease {
    public static func writeAndInstall(
        containerName: String,
        script: String,
        dependencies: [String: String],
        exec: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult
    ) async throws {
        let scriptResult = try await exec(
            DockerScriptPreparer.dockerExecWriteScriptArguments(containerName: containerName),
            Data(script.utf8),
            30
        )
        if scriptResult.exitCode != 0 {
            throw ScriptLeaseError.execFailed("write script", scriptResult)
        }

        let tsconfig = try await exec(
            DockerScriptPreparer.dockerExecWriteTSConfigArguments(containerName: containerName),
            Data(DerrickGuestTypeScript.tsconfigJSON.utf8),
            30
        )
        if tsconfig.exitCode != 0 {
            throw ScriptLeaseError.execFailed("write tsconfig", tsconfig)
        }

        let check = try await exec(
            DockerScriptPreparer.dockerExecWriteHandleCheckArguments(containerName: containerName),
            Data(DerrickGuestTypeScript.handleCheckTS.utf8),
            30
        )
        if check.exitCode != 0 {
            throw ScriptLeaseError.execFailed("write handle-check", check)
        }

        let packageJSON = DockerScriptPreparer.makePackageJSON(dependencies: dependencies)
        let pkgResult = try await exec(
            DockerScriptPreparer.dockerExecWritePackageJSONArguments(containerName: containerName),
            Data(packageJSON.utf8),
            30
        )
        if pkgResult.exitCode != 0 {
            throw ScriptLeaseError.execFailed("write package.json", pkgResult)
        }

        if !dependencies.isEmpty {
            let install = try await exec(
                DockerScriptPreparer.dockerExecInstallArguments(containerName: containerName),
                Data(),
                180
            )
            if install.exitCode != 0 {
                throw ScriptLeaseError.execFailed("bun install", install)
            }
        }

        let tsc = try await exec(
            DockerScriptPreparer.dockerExecTscArguments(containerName: containerName),
            Data(),
            60
        )
        if tsc.exitCode != 0 {
            let out = String(decoding: tsc.stdout, as: UTF8.self)
            let err = String(decoding: tsc.stderr, as: UTF8.self)
            var message = [out, err]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if message.isEmpty {
                message = "tsc failed (exit \(tsc.exitCode)) with no output."
            }
            if message.count > 8_000 {
                message = String(message.prefix(8_000)) + "\n…"
            }
            throw ScriptLeaseError.typecheckFailed(message)
        }
    }

    public static func isolateNetwork(
        containerName: String,
        exec: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult
    ) async throws {
        do {
            try await DockerNetworkContainerPool.shared.handoffToOffline(containerName: containerName) { args, stdin, timeout in
                try await exec(args, stdin, timeout)
            }
        } catch {
            throw ScriptLeaseError.execFailed(
                "handoff --network none",
                DockerCLIResult(exitCode: 1, stdout: Data(), stderr: Data(error.localizedDescription.utf8))
            )
        }
    }

    public static func runHandle(
        containerName: String,
        invokeJSON: Data,
        timeoutSeconds: Int,
        exec: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult
    ) async throws -> ScriptHopResult {
        let result = try await exec(
            DockerScriptPreparer.dockerExecRunnerArguments(containerName: containerName),
            invokeJSON,
            timeoutSeconds
        )
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        var envelopes: [PluginEnvelope] = []
        if result.exitCode == 0 {
            envelopes = try PluginEnvelopeList.decode(Data(stdout.utf8))
        }
        return ScriptHopResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: result.exitCode,
            envelopes: envelopes
        )
    }
}

public enum ScriptLeaseError: Error, LocalizedError {
    case execFailed(String, DockerCLIResult)
    case typecheckFailed(String)

    public var errorDescription: String? {
        switch self {
        case .execFailed(let step, let result):
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            return "\(step) failed (exit \(result.exitCode)): \(stderr)"
        case .typecheckFailed(let message):
            return "TypeScript check failed:\n\(message)"
        }
    }
}
