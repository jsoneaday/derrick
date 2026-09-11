package newsreader

import (
	"net/url"
	"strings"
)

func CanonicalFetchURL(raw string, contextHint string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	host := strings.ToLower(parsed.Hostname())
	if !strings.Contains(host, "news.google.com") {
		return raw
	}
	path := strings.ToLower(parsed.Path)
	if strings.Contains(path, "/rss") || strings.HasSuffix(path, ".xml") {
		return raw
	}
	if strings.Contains(path, "/topics/") {
		if section := googleNewsSection(contextHint); section != "" {
			return "https://news.google.com/rss/headlines/section/topic/" + section + "?hl=en-US&gl=US&ceid=US:en"
		}
		return "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en"
	}
	if parsed.RawQuery == "" {
		return "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en"
	}
	return raw
}

func googleNewsSection(hint string) string {
	lower := strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(hint, "-", " "), "_", " "))
	if strings.Contains(lower, "tech") {
		return "TECHNOLOGY"
	}
	if strings.Contains(lower, "business") || strings.Contains(lower, "finance") || strings.Contains(lower, "market") {
		return "BUSINESS"
	}
	if strings.Contains(lower, "science") {
		return "SCIENCE"
	}
	if strings.Contains(lower, "sport") {
		return "SPORTS"
	}
	if strings.Contains(lower, "health") {
		return "HEALTH"
	}
	if strings.Contains(lower, "entertainment") {
		return "ENTERTAINMENT"
	}
	if strings.Contains(lower, "world") {
		return "WORLD"
	}
	return ""
}
