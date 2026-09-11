import Foundation
import Structure
import WebCrawler

/// Host-side helpers for preparing news reader Docker input and egress policy.
enum NewsReaderDockerInputPreparer {
    static func enrich(_ input: Data) async throws -> (data: Data, leaseHosts: [String]) {
        let request: NewsReaderWorkerRequest
        do {
            request = try JSONDecoder.service.decode(NewsReaderWorkerRequest.self, from: input)
        } catch {
            throw NewsReaderDockerExecutorError.commandFailed(
                "prepare news reader container",
                "News reader input was not valid JSON."
            )
        }
        guard !request.sources.isEmpty else {
            throw NewsReaderDockerExecutorError.commandFailed(
                "prepare news reader container",
                "News reader input did not include any sources."
            )
        }

        var hosts = Set<String>()
        for source in request.sources {
            guard let url = URL(string: source.url) else {
                throw NewsReaderDockerExecutorError.commandFailed(
                    "prepare news reader container",
                    "Source URL is not valid: \(source.url)"
                )
            }
            let chain = await WebCrawlerRedirectResolver.hostsInRedirectChain(from: url)
            hosts.formUnion(chain)
        }
        guard !hosts.isEmpty else {
            throw NewsReaderDockerExecutorError.commandFailed(
                "prepare news reader container",
                "Could not determine hosts to fetch from the configured sources."
            )
        }
        return (input, Array(hosts).sorted())
    }
}
