import Foundation
import DockerRunnerXPC
import Plugin

/// Write files onto a named volume: create → start → exec -i (stdin) → rm -f.
/// Never `docker cp`. Helpers volume is populated this way at prewarm.
public enum DockerVolumeIO {
    public static func writeFile(
        volume: String,
        relativePath: String,
        data: Data,
        exec: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult
    ) async throws {
        let dest = try Self.validatedRelativePath(relativePath)
        let name = DerrickNamedVolume.volumeIOContainer(suffix: UUID().uuidString)
        let create = try await exec(
            [
                "create",
                "--network", "none",
                "--name", name,
                "--init",
                "--tmpfs", "/tmp:rw,nosuid,size=64m",
                "-v", "\(volume):/mnt",
                "--security-opt", "no-new-privileges",
                "--cap-drop", "ALL",
                "--entrypoint", DockerScriptPreparer.holdBinary,
                DockerScriptPreparer.defaultImage,
                DockerScriptPreparer.holdArg,
            ],
            Data(),
            30
        )
        if create.exitCode != 0 {
            throw ScriptLeaseError.execFailed("volumeio create", create)
        }

        do {
            let start = try await exec(DockerScriptPreparer.dockerStartArguments(containerName: name), Data(), 15)
            if start.exitCode != 0 {
                throw ScriptLeaseError.execFailed("volumeio start", start)
            }

            guard !data.isEmpty else {
                throw VolumeIOPathError.emptyPayload(dest)
            }
            let js = "const p='/mnt/\(dest)';const b=await Bun.stdin.bytes();if(b.byteLength===0)throw new Error('volumeio stdin empty');await Bun.write(p,b);const n=(await Bun.file(p).arrayBuffer()).byteLength;if(n!==b.byteLength)throw new Error('volumeio short write');process.stdout.write(String(n));"
            let write = try await exec(
                ["exec", "-i", name, "bun", "-e", js],
                data,
                30
            )
            if write.exitCode != 0 {
                throw ScriptLeaseError.execFailed("volumeio write \(dest)", write)
            }
            let wrote = Int(
                String(decoding: write.stdout, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? -1
            if wrote != data.count {
                throw ScriptLeaseError.execFailed(
                    "volumeio write \(dest) size \(wrote) != \(data.count)",
                    write
                )
            }
        } catch {
            _ = try? await exec(DockerScriptPreparer.dockerRmForceArguments(container: name), Data(), 15)
            throw error
        }
        _ = try await exec(DockerScriptPreparer.dockerRmForceArguments(container: name), Data(), 15)
    }

    public static func ensureVolume(
        name: String,
        exec: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult
    ) async throws {
        let result = try await exec(DockerScriptPreparer.dockerVolumeCreateArguments(name: name), Data(), 15)
        if result.exitCode != 0 {
            let stderr = String(decoding: result.stderr, as: UTF8.self).lowercased()
            if !stderr.contains("already exists") {
                throw ScriptLeaseError.execFailed("volume create \(name)", result)
            }
        }
    }

    public static func injectHelpers(
        exec: @escaping @Sendable ([String], Data, Int) async throws -> DockerCLIResult
    ) async throws {
        try await ensureVolume(name: DerrickNamedVolume.helpers, exec: exec)
        try await writeFile(
            volume: DerrickNamedVolume.helpers,
            relativePath: "runner.ts",
            data: Data(DockerScriptPreparer.guestRunner.utf8),
            exec: exec
        )
        try await writeFile(
            volume: DerrickNamedVolume.helpers,
            relativePath: "derrick.ts",
            data: Data(DerrickGuestTypeScript.derrickModule.utf8),
            exec: exec
        )
        try await writeFile(
            volume: DerrickNamedVolume.helpers,
            relativePath: "handle-return.schema.json",
            data: Data(PluginEnvelopeSchema.jsonSchema.utf8),
            exec: exec
        )
    }

    public static func validatedRelativePath(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("..") else {
            throw VolumeIOPathError.invalidRelativePath(raw)
        }
        return trimmed
    }
}

public enum VolumeIOPathError: Error, LocalizedError {
    case invalidRelativePath(String)
    case emptyPayload(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let p):
            return "VolumeIO path must be volume-relative: \(p)"
        case .emptyPayload(let p):
            return "VolumeIO refused empty payload for \(p)"
        }
    }
}
