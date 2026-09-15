package search

import (
	"net/url"
	"strings"

	"github.com/PuerkitoBio/goquery"
)

func parseHits(html string, maxResults int) []Hit {
	doc, err := goquery.NewDocumentFromReader(strings.NewReader(html))
	if err != nil {
		return nil
	}
	hits := parseHTMLHits(doc, maxResults)
	if len(hits) == 0 {
		hits = parseLiteHits(doc, maxResults)
	}
	return hits
}

func parseHTMLHits(doc *goquery.Document, maxResults int) []Hit {
	var hits []Hit
	doc.Find("a.result__a").Each(func(_ int, sel *goquery.Selection) {
		if len(hits) >= maxResults {
			return
		}
		if sel.Closest(".result--ad, .badge-ad").Length() > 0 {
			return
		}
		title := strings.TrimSpace(sel.Text())
		href, _ := sel.Attr("href")
		resolved := unwrapDuckDuckGoURL(href)
		if title == "" || !isHTTPURL(resolved) {
			return
		}
		snippet := strings.TrimSpace(sel.Closest(".result").Find(".result__snippet").First().Text())
		hits = append(hits, Hit{Title: title, URL: resolved, Snippet: snippet})
	})
	return hits
}

func parseLiteHits(doc *goquery.Document, maxResults int) []Hit {
	var hits []Hit
	doc.Find("a.result-link").Each(func(_ int, sel *goquery.Selection) {
		if len(hits) >= maxResults {
			return
		}
		title := strings.TrimSpace(sel.Text())
		href, _ := sel.Attr("href")
		resolved := unwrapDuckDuckGoURL(href)
		if title == "" || !isHTTPURL(resolved) {
			return
		}
		row := sel.Closest("tr")
		snippet := strings.TrimSpace(row.Next().Find(".result-snippet").First().Text())
		if snippet == "" {
			snippet = strings.TrimSpace(row.Parent().Find(".result-snippet").First().Text())
		}
		hits = append(hits, Hit{Title: title, URL: resolved, Snippet: snippet})
	})
	return hits
}

func unwrapDuckDuckGoURL(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	if strings.HasPrefix(trimmed, "//") {
		trimmed = "https:" + trimmed
	}
	parsed, err := url.Parse(trimmed)
	if err != nil {
		return ""
	}
	if encoded := parsed.Query().Get("uddg"); encoded != "" {
		decoded, err := url.QueryUnescape(encoded)
		if err == nil && isHTTPURL(decoded) {
			return decoded
		}
	}
	if isHTTPURL(parsed.String()) && !isDuckDuckGoHost(parsed.Hostname()) {
		return parsed.String()
	}
	return ""
}

func isHTTPURL(raw string) bool {
	parsed, err := url.Parse(raw)
	if err != nil {
		return false
	}
	scheme := strings.ToLower(parsed.Scheme)
	return (scheme == "http" || scheme == "https") && parsed.Host != "" && parsed.User == nil
}

func isDuckDuckGoHost(host string) bool {
	h := strings.ToLower(host)
	return h == "duckduckgo.com" || strings.HasSuffix(h, ".duckduckgo.com")
}
