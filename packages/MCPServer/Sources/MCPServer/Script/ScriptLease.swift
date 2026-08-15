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
    }

    public static func isolateNetwork(
        containerName: String,
        exec: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult
    ) async throws {
        do {
            try await DockerNetworkContainerPool.shared.handoffToOffline(containerName: containerName) { args, timeout in
                try await exec(args, Data(), timeout)
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

    public var errorDescription: String? {
        switch self {
        case .execFailed(let step, let result):
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            return "\(step) failed (exit \(result.exitCode)): \(stderr)"
        }
    }
}
