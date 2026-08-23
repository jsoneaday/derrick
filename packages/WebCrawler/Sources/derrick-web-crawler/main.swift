import Foundation
import WebCrawler

let input = FileHandle.standardInput.readDataToEndOfFile()
let decoder = JSONDecoder()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

let result: WebCrawlerResult
if let request = try? decoder.decode(WebCrawlerRequest.self, from: input) {
    let environment = ProcessInfo.processInfo.environment
    result = await WebCrawlerEngine.run(
        request: request,
        proxyHost: environment["DERRICK_EGRESS_PROXY_HOST"],
        proxyPort: environment["DERRICK_EGRESS_PROXY_PORT"].flatMap(Int.init),
        proxyToken: environment["DERRICK_EGRESS_PROXY_TOKEN"]
    )
} else {
    result = WebCrawlerResult(
        ok: false,
        startURL: "",
        pages: [],
        stopReason: .blocked,
        requestsMade: 0,
        bytesRead: 0,
        truncated: false,
        diagnostics: ["Crawler input must be a valid JSON object."]
    )
}

if let output = try? encoder.encode(result) {
    FileHandle.standardOutput.write(output)
}
