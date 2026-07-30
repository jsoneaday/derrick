import Foundation
import Testing
@testable import Lib

@Suite struct ToolArgumentsJSONTests {
    @Test func parsesValidArguments() throws {
        let json = #"{"mode":"readonly","allow_network":true,"script":"print(1)"}"#
        let args = try parseToolArgumentsObject(json)
        #expect(args["mode"] != nil)
        #expect(args["script"] != nil)
    }

    @Test func sanitizesIllegalDollarEscapeFromPythonRegex() throws {
        let json = #"{"mode":"readonly","script":"p=re.search(r'\$\s?[0-9]+', s)","allow_network":true}"#
        #expect(strictParse(json) == false)

        let args = try parseToolArgumentsObject(json)
        guard case .string(let script)? = args["script"] else {
            Issue.record("expected script string")
            return
        }
        #expect(script.contains("$"))
        #expect(args["mode"] != nil)
    }

    @Test func repairsBareQuotesInsideScriptCSSSelector() throws {
        let broken = brokenArguments(
            script: "for item in soup.select('div[data-component-type=\"s-search-result\"]')[:20]:\n    pass"
        )
        #expect(strictParse(broken) == false)

        let args = try parseToolArgumentsObject(broken)
        guard case .string(let script)? = args["script"] else {
            Issue.record("expected recovered script")
            return
        }
        #expect(script.contains("s-search-result"))
        #expect(args["mode"] != nil)
        #expect(args["allow_network"] != nil)
    }

    @Test func repairsFullLengthAmazonStyleScript() throws {
        let script = [
            "from bs4 import BeautifulSoup",
            "import requests",
            "url='https://www.amazon.com/s?k=bicycle'",
            "headers={'User-Agent':'Mozilla/5.0','Accept-Language':'en-US,en;q=0.9'}",
            "r=requests.get(url, headers=headers, timeout=30)",
            "soup=BeautifulSoup(r.text,'lxml')",
            "results=[]",
            "for item in soup.select('div[data-component-type=\"s-search-result\"]')[:20]:",
            "    title_tag=item.select_one('h2 a span')",
            "    link_tag=item.select_one('h2 a')",
            "    price_tag=item.select_one('.a-price .a-offscreen')",
            "    if not title_tag or not link_tag: continue",
            "    title=title_tag.get_text(strip=True)",
            "    href=link_tag.get('href')",
            "    if href and href.startswith('/'): href='https://www.amazon.com'+href",
            "    price=price_tag.get_text(strip=True) if price_tag else None",
            "    asin=item.get('data-asin')",
            "    if asin and any(d.get('asin')==asin for d in results): continue",
            "    results.append({'title':title,'url':href,'price':price,'asin':asin})",
            "    if len(results)>=10: break",
            "import json",
            "print(json.dumps(results, ensure_ascii=False))"
        ].joined(separator: "\n")

        let broken = brokenArguments(script: script, includePackages: true)
        #expect(strictParse(broken) == false)

        let args = try parseToolArgumentsObject(broken)
        guard case .string(let recovered)? = args["script"] else {
            Issue.record("expected script")
            return
        }
        #expect(recovered.contains("amazon.com"))
        #expect(recovered.contains("s-search-result"))
        #expect(recovered.contains("print(json.dumps"))
        #expect(args["python_packages"] != nil)
        #expect(args["timeout_seconds"] != nil)
        #expect(args["description"] != nil)
    }

    @Test func repairsIllegalEscapeAndBareQuotesTogether() throws {
        let script = "p=re.search(r'\\$\\s?', x); soup.select('div[data-component-type=\"s-search-result\"]')"
        // script above has real $ illegal-escape when embedded... use brokenArguments which embeds raw
        let broken = brokenArguments(
            script: #"p=re.search(r'\$\s?', x); soup.select('div[data-component-type="s-search-result"]')"#
        )
        #expect(strictParse(broken) == false)

        let args = try parseToolArgumentsObject(broken)
        #expect(args["script"] != nil)
        #expect(args["mode"] != nil)
    }

    @Test func validPayloadUnchangedRoundTrip() throws {
        let script = "print('hello')"
        let payload: [String: Any] = [
            "mode": "readonly",
            "allow_network": true,
            "script": script
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let valid = String(data: data, encoding: .utf8)!
        #expect(strictParse(valid) == true)

        let args = try parseToolArgumentsObject(valid)
        guard case .string(let s)? = args["script"] else {
            Issue.record("expected script")
            return
        }
        #expect(s == script)
    }

    @Test func productionLogStyleUnderEscapedCSSQuotes() throws {
        // Simulates AgentResponse.toolCall.arguments after outer JSONDecoder decode
        // when the model under-escaped CSS attribute quotes (the 2026-07-30 failure).
        let broken = brokenArguments(
            script: "soup=BeautifulSoup(r.text,'lxml')\nfor item in soup.select('div[data-component-type=\"s-search-result\"]')[:20]:\n    pass\nprint(json.dumps(results, ensure_ascii=False))",
            includePackages: true
        )
        #expect(strictParse(broken) == false)
        let args = try parseToolArgumentsObject(broken)
        guard case .string(let script)? = args["script"] else {
            Issue.record("expected script")
            return
        }
        #expect(script.contains("s-search-result"))
        #expect(script.contains("BeautifulSoup"))
    }

    /// Build invalid tool-arguments JSON: `script` contains raw `"` and real newlines.
    private func brokenArguments(script: String, includePackages: Bool = false) -> String {
        var s = #"{"mode":"readonly","allow_network":true,"script":""#
        s += script
        s += "\""
        s += #","timeout_seconds":120"#
        if includePackages {
            s += #","python_packages":["requests","beautifulsoup4","lxml"]"#
            // Use regular strings carefully so closing quotes are real content.
            s += ",\"description\":\"Fetch Amazon.com search results for bicycle\""
            s += ",\"reason\":\"User requested top 10 bicycles\""
        }
        s += "}"
        return s
    }

    private func strictParse(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            return false
        }
        return true
    }
}
