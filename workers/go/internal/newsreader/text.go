package newsreader

import (
	"net/url"
	"regexp"
	"strings"
)

var tagPattern = regexp.MustCompile(`<[^>]+>`)
var hrefPattern = regexp.MustCompile(`(?i)href\s*=\s*"([^"]+)"`)
var whitespacePattern = regexp.MustCompile(`\s+`)

func StripTags(raw string) string {
	value := tagPattern.ReplaceAllString(raw, " ")
	value = strings.ReplaceAll(value, "<![CDATA[", "")
	value = strings.ReplaceAll(value, "]]>", "")
	return DecodeEntities(value)
}

func DecodeEntities(raw string) string {
	replacements := []struct {
		from string
		to   string
	}{
		{"&amp;", "&"},
		{"&lt;", "<"},
		{"&gt;", ">"},
		{"&quot;", "\""},
		{"&#39;", "'"},
		{"&apos;", "'"},
		{"&nbsp;", " "},
	}
	value := raw
	for _, pair := range replacements {
		value = strings.ReplaceAll(value, pair.from, pair.to)
	}
	return value
}

func CollapseWhitespace(raw string) string {
	return strings.TrimSpace(whitespacePattern.ReplaceAllString(raw, " "))
}

func SanitizeDetail(raw string, maxLen int) string {
	cleaned := CollapseWhitespace(StripTags(raw))
	if cleaned == "" {
		return ""
	}
	if len(cleaned) <= maxLen {
		return cleaned
	}
	return strings.TrimSpace(cleaned[:maxLen]) + "…"
}

func PreferredArticleURL(link string, htmlSnippet string) string {
	link = strings.TrimSpace(link)
	for _, match := range hrefPattern.FindAllStringSubmatch(htmlSnippet, -1) {
		if len(match) < 2 {
			continue
		}
		href := strings.TrimSpace(match[1])
		if !strings.HasPrefix(href, "http") {
			continue
		}
		parsed, err := url.Parse(href)
		if err != nil {
			continue
		}
		host := strings.ToLower(parsed.Hostname())
		if strings.Contains(host, "google.com") || strings.Contains(host, "googleusercontent.com") {
			continue
		}
		return href
	}
	return link
}
