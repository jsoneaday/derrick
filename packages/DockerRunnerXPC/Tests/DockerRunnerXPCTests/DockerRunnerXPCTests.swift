import Foundation
import Testing
@testable import DockerRunnerXPC

struct DockerRunnerXPCTests {
    @Test func peerRequirementIncludesMainAppIdentifier() {
        let requirement = XPCPeerAuthentication.requirementString(
            allowedPeerIdentifiers: [XPCPeerAuthentication.mainAppIdentifier],
            teamIdentifier: "ABCDE12345"
        )
        #expect(requirement.contains("identifier \"derrick.ui\""))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
        #expect(requirement.contains("anchor apple generic"))
    }

    @Test func peerRequirementIncludesHelperIdentifier() {
        let requirement = XPCPeerAuthentication.requirementString(for: .appConnectingToHelper)
        #expect(requirement.contains("identifier \"derrick.ui.DockerRunnerHelper\""))
    }

    @Test func peerRequirementIncludesMCPIdentifier() {
        let requirement = XPCPeerAuthentication.requirementString(for: .helperAcceptingMCP)
        #expect(requirement.contains("identifier \"derrick.ui.MCPService\""))
    }

    @Test func peerRequirementsRestrictAgentAndJobMesh() {
        let agentRequirement = XPCPeerAuthentication.requirementString(for: .agentAcceptingJob)
        #expect(agentRequirement.contains("identifier \"derrick.ui.JobService\""))
        #expect(!agentRequirement.contains("derrick.ui.MCPService"))

        let jobRequirement = XPCPeerAuthentication.requirementString(for: .jobAcceptingAgentAndMCP)
        #expect(jobRequirement.contains("identifier \"derrick.ui.AgentService\""))
        #expect(jobRequirement.contains("identifier \"derrick.ui.MCPService\""))

        let mcpRequirement = XPCPeerAuthentication.requirementString(for: .mcpAcceptingAgentAndJob)
        #expect(mcpRequirement.contains("identifier \"derrick.ui.AgentService\""))
        #expect(mcpRequirement.contains("identifier \"derrick.ui.JobService\""))
    }

    @Test func peerRequirementWithoutTeamUsesIdentifierOnly() {
        let requirement = XPCPeerAuthentication.requirementString(
            allowedPeerIdentifiers: ["derrick.ui"],
            teamIdentifier: nil
        )
        #expect(requirement == "identifier \"derrick.ui\"")
    }

    @Test func peerRequirementORsMultipleIdentifiers() {
        let requirement = XPCPeerAuthentication.requirementString(
            allowedPeerIdentifiers: ["derrick.ui", "derrick.ui.bridge"],
            teamIdentifier: "TEAM1"
        )
        #expect(requirement.contains("identifier \"derrick.ui\""))
        #expect(requirement.contains("identifier \"derrick.ui.bridge\""))
        #expect(requirement.contains(" or "))
    }

    @Test func debugModeRequiresExplicitTrue() {
        #expect(XPCPeerAuthentication.isDebugMode(environment: ["IS_DEBUG": "true"]))
        #expect(XPCPeerAuthentication.isDebugMode(environment: ["IS_DEBUG": "TRUE"]))
        #expect(!XPCPeerAuthentication.isDebugMode(environment: ["IS_DEBUG": "false"]))
        #expect(!XPCPeerAuthentication.isDebugMode(environment: [:]))
    }

    private func request(
        executable: String = DockerHostLaunch.envExecutablePath,
        arguments: [String] = DockerHostLaunch.dockerCLIArguments(["version"]),
        environment: [String: String] = [:],
        stdin: Data = Data(),
        timeout: Int = 30
    ) -> DockerRunRequest {
        DockerRunRequest(
            executablePath: executable,
            arguments: arguments,
            environment: environment,
            stdinData: stdin,
            timeoutSeconds: timeout
        )
    }

    @Test func requestRoundTripsThroughJSON() throws {
        let request = DockerHostLaunch.makeRequest(
            dockerArguments: ["run", "--rm", "image"],
            stdinData: Data("print(1)".utf8),
            timeoutSeconds: 30
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(DockerRunRequest.self, from: data)
        #expect(decoded.executablePath == DockerHostLaunch.envExecutablePath)
        #expect(decoded.arguments.first == DockerHostLaunch.dockerCommandName)
        #expect(decoded.stdinData == Data("print(1)".utf8))
    }

    @Test func responseRoundTripsThroughJSON() throws {
        let response = DockerRunResponse(
            stdout: Data("ok".utf8),
            stderr: Data(),
            exitCode: 0,
            timedOut: false,
            launchError: nil,
            logs: ["started", "finished"]
        )
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(DockerRunResponse.self, from: data)
        #expect(decoded.stdout == response.stdout)
        #expect(decoded.exitCode == 0)
        #expect(decoded.logs == response.logs)
    }

    @Test func processAllowlistAcceptsEnvDocker() {
        #expect(DockerRunRequestValidator.validate(request()) == nil)
    }

    @Test func processAllowlistRejectsShell() {
        let r = request(executable: "/bin/zsh", arguments: ["-c", "echo hi"])
        #expect(DockerRunRequestValidator.validate(r) == .disallowedExecutable("/bin/zsh"))
    }

    @Test func processAllowlistRejectsEnvWithoutDocker() {
        let r = request(arguments: ["bun", "-e", "print(1)"])
        #expect(DockerRunRequestValidator.validate(r) == .missingDockerInvocation)
    }

    @Test func processAllowlistRejectsEmptyArgs() {
        let r = request(arguments: [])
        #expect(DockerRunRequestValidator.validate(r) == .missingArguments)
    }

    @Test func processAllowlistRejectsRelativePath() {
        let r = request(executable: "env", arguments: [DockerHostLaunch.dockerCommandName])
        #expect(DockerRunRequestValidator.validate(r) == .relativeExecutablePath("env"))
    }

    @Test func rejectsDisallowedDockerSubcommand() {
        let r = request(arguments: DockerHostLaunch.dockerCLIArguments(["system", "prune", "-af"]))
        #expect(DockerRunRequestValidator.validate(r) == .disallowedDockerSubcommand("system"))
    }

    @Test func rejectsPrivilegedFlag() {
        let r = request(arguments: DockerHostLaunch.dockerCLIArguments([
            "create", "--privileged", "--name", "x", "image"
        ]))
        #expect(DockerRunRequestValidator.validate(r) == .disallowedDockerFlag("--privileged"))
    }

    @Test func rejectsHostNetwork() {
        let r = request(arguments: DockerHostLaunch.dockerCLIArguments([
            "create", "--network", "host", "--name", "x", "image"
        ]))
        #expect(DockerRunRequestValidator.validate(r) == .disallowedDockerFlag("--network=host"))
    }

    @Test func rejectsHostBindMount() {
        let r = request(arguments: DockerHostLaunch.dockerCLIArguments([
            "create", "-v", "/:/host", "--name", "x", "image"
        ]))
        #expect(DockerRunRequestValidator.validate(r) == .disallowedVolumeMount("/:/host"))
    }

    @Test func acceptsNamedVolumeMount() {
        let r = request(arguments: DockerHostLaunch.dockerCLIArguments([
            "create", "-v", "derrick-pip-cache:/root/.cache", "--name", "x", "image"
        ]))
        #expect(DockerRunRequestValidator.validate(r) == nil)
    }

    @Test func acceptsProductSubcommands() {
        for args in [
            ["version"],
            ["volume", "inspect", "derrick-pip-cache"],
            ["image", "inspect", "img"],
            ["build", "-t", "img", "-"],
            ["pull", "img"],
            ["exec", "-i", "c", "bun", "-"],
            ["start", "c"],
            ["rm", "-f", "c"],
            ["inspect", "-f", "{{.State.Running}}", "c"]
        ] as [[String]] {
            let r = request(arguments: DockerHostLaunch.dockerCLIArguments(args))
            #expect(DockerRunRequestValidator.validate(r) == nil, "expected allow for \(args)")
        }
    }

    @Test func rejectsTimeoutOutOfRange() {
        #expect(DockerRunRequestValidator.validate(request(timeout: 0)) == .timeoutOutOfRange(0))
        #expect(
            DockerRunRequestValidator.validate(request(timeout: DockerHostLaunch.maxTimeoutSeconds + 1))
                == .timeoutOutOfRange(DockerHostLaunch.maxTimeoutSeconds + 1)
        )
    }

    @Test func rejectsOversizedStdin() {
        let big = Data(repeating: 0x41, count: DockerHostLaunch.maxStdinBytes + 1)
        #expect(DockerRunRequestValidator.validate(request(stdin: big)) == .stdinTooLarge(big.count))
    }

    @Test func approveUsesHelperEnvironmentIgnoringClient() {
        let r = request(environment: ["PATH": "/evil", "HOME": "/tmp/evil"])
        switch DockerRunRequestValidator.approve(r, homeDirectory: "/Users/test", temporaryDirectory: "/tmp") {
        case .failure(let error):
            Issue.record("unexpected failure \(error)")
        case .success(let launch):
            #expect(launch.environment["PATH"] == DockerHostLaunch.pathEnvironmentValue)
            #expect(launch.environment["HOME"] == "/Users/test")
            #expect(launch.environment["DOCKER_HOST"] == "unix:///Users/test/.docker/run/docker.sock")
            #expect(launch.environment["PATH"] != "/evil")
            #expect(launch.executablePath == DockerHostLaunch.envExecutablePath)
        }
    }

    @Test func validationErrorUsesStablePrefix() {
        let message = DockerRunRequestValidationError.disallowedExecutable("/bin/sh").launchErrorMessage
        #expect(message.hasPrefix(DockerRunRequestValidationError.launchErrorPrefix))
    }

    @Test func hostLaunchConstantsAreStable() {
        #expect(DockerHostLaunch.envExecutablePath == "/usr/bin/env")
        #expect(DockerHostLaunch.dockerCommandName == "docker")
        #expect(DockerHostLaunch.dockerCLIArguments(["version"]) == ["docker", "version"])
    }
}
