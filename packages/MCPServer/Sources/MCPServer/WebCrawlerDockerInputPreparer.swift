import Foundation
import WebCrawler
import Structure

/// Host-side helpers for preparing crawler Docker input and egress policy.
enum WebCrawlerDockerInputPreparer {
    static func enrich(_ input: Data) async throws -> (data: Data, leaseHosts: [String]) {
        guard var object = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
            throw WebCrawlerDockerExecutorError.commandFailed(
                "prepare crawler container",
                "Crawler input was not a JSON object."
            )
        }
        guard let rawURL = object["start_url"] as? String,
              let url = URL(string: rawURL)
        else {
            throw WebCrawlerDockerExecutorError.commandFailed(
                "prepare crawler container",
                "Crawler input did not contain a valid start_url."
            )
        }

        let redirectHosts = await WebCrawlerRedirectResolver.hostsInRedirectChain(from: url)
        object["allowed_hosts"] = redirectHosts.sorted()
        let enriched = try JSONSerialization.data(withJSONObject: object)
        return (enriched, Array(redirectHosts))
    }
}
