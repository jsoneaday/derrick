import Foundation

/// Parsed `test_input_json` for factory direct tests.
/// Connectors use a `hops` array replayed in order; simple plugins may use a single hop event.
public struct PluginFactoryTestScript: Sendable, Hashable {
    public let hops: [PluginHopEvent]

    public init(hops: [PluginHopEvent]) {
        self.hops = hops
    }

    public static func parse(_ data: Data) throws -> PluginFactoryTestScript {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginFactoryError.invalidSource("test_input_json must be a JSON object.")
        }
        if object["hops"] != nil {
            guard let rawHops = object["hops"] as? [Any] else {
                throw PluginFactoryError.invalidSource("test_input_json hops must be a JSON array.")
            }
            guard !rawHops.isEmpty else {
                throw PluginFactoryError.invalidSource("test_input_json hops must not be empty.")
            }
            var hops: [PluginHopEvent] = []
            hops.reserveCapacity(rawHops.count)
            for (index, element) in rawHops.enumerated() {
                guard JSONSerialization.isValidJSONObject(element),
                      let hopData = try? JSONSerialization.data(withJSONObject: element) else {
                    throw PluginFactoryError.invalidSource(
                        "test_input_json hop at index \(index) must be a JSON object."
                    )
                }
                try GuestContractValidation.validateHopEventJSON(hopData)
                hops.append(try JSONDecoder().decode(PluginHopEvent.self, from: hopData))
            }
            return PluginFactoryTestScript(hops: hops)
        }

        try GuestContractValidation.validateHopEventJSON(data)
        let hop = try JSONDecoder().decode(PluginHopEvent.self, from: data)
        return PluginFactoryTestScript(hops: [hop])
    }

    /// Returns a copy with http_results fixture order reversed in every hop that has fixtures.
    public func withShuffledHTTPResults() -> PluginFactoryTestScript {
        PluginFactoryTestScript(
            hops: hops.map { hop in
                guard var results = hop.httpResults, results.count > 1 else { return hop }
                results.reverse()
                return PluginHopEvent(
                    kind: hop.kind,
                    httpResults: results,
                    params: hop.params
                )
            }
        )
    }

    public func encoded() throws -> Data {
        if hops.count == 1, hops[0].httpResults == nil || hops[0].httpResults?.isEmpty == true {
            return try JSONEncoder().encode(hops[0])
        }
        let object: [String: Any] = [
            "hops": try hops.map { hop in
                let data = try JSONEncoder().encode(hop)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw PluginFactoryError.invalidSource("Could not encode test hop.")
                }
                return json
            },
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// Replays scripted hop events against draft guest source until a terminal envelope or hop budget.
public enum PluginFactoryHopTestRunner: Sendable {
    public static func run(
        source: String,
        testInput: Data,
        executor: any PluginFactoryExecutor
    ) async throws -> PluginFactoryHopTestRun {
        try await run(testInput: testInput) { input in
            try await executor.runGuestSource(source: source, input: input)
        }
    }

    public static func run(
        artifact: Data,
        testInput: Data,
        executor: any PluginFactoryExecutor
    ) async throws -> PluginFactoryHopTestRun {
        try await run(testInput: testInput) { input in
            try await executor.runPackagedArtifact(artifact, input: input)
        }
    }

    public static func run(
        testInput: Data,
        execute: @Sendable (Data) async throws -> PluginFactoryExecutionResult
    ) async throws -> PluginFactoryHopTestRun {
        let script = try PluginFactoryTestScript.parse(testInput)
        var hopResults: [PluginFactoryExecutionResult] = []
        var lastResult = PluginFactoryExecutionResult(exitCode: 1)

        for hop in script.hops {
            let input = try JSONEncoder().encode(hop)
            let result = try await execute(input)
            hopResults.append(result)
            lastResult = result
            guard result.exitCode == 0 else {
                return PluginFactoryHopTestRun(final: result, hopResults: hopResults)
            }
        }

        return PluginFactoryHopTestRun(final: lastResult, hopResults: hopResults)
    }
}

public struct PluginFactoryHopTestRun: Sendable, Hashable {
    public let final: PluginFactoryExecutionResult
    public let hopResults: [PluginFactoryExecutionResult]

    public init(final: PluginFactoryExecutionResult, hopResults: [PluginFactoryExecutionResult]) {
        self.final = final
        self.hopResults = hopResults
    }

    /// Combined stdout from every replayed hop for safety review and logging.
    public var aggregatedDirectRun: PluginFactoryExecutionResult {
        let stdout = hopResults
            .map { String(decoding: $0.stdout, as: UTF8.self) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return PluginFactoryExecutionResult(
            exitCode: final.exitCode,
            stdout: Data(stdout.utf8),
            stderr: final.stderr
        )
    }
}
