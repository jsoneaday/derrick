import Foundation
import Testing
@testable import ui

@Suite
struct JobOrderPreflightTests {
    @Test
    func webCrawlStartHostReadsStartURL() {
        let host = JobOrderPreflight.webCrawlStartHost(
            toolArgumentsJSON: #"{"start_url":"https://WWW.Example.com/path","goal":"Read the page"}"#
        )
        #expect(host == "www.example.com")
    }

    @Test
    func webCrawlStartHostRejectsMissingURL() {
        #expect(JobOrderPreflight.webCrawlStartHost(toolArgumentsJSON: #"{"goal":"Read the page"}"#) == nil)
        #expect(JobOrderPreflight.webCrawlStartHost(toolArgumentsJSON: "not-json") == nil)
    }
}
