package newsreader

import (
	"encoding/xml"
	"regexp"
	"strings"
)

type rssFeed struct {
	Channel rssChannel `xml:"channel"`
}

type rssChannel struct {
	Items []rssItem `xml:"item"`
}

type rssItem struct {
	Title       string `xml:"title"`
	Link        string `xml:"link"`
	Description string `xml:"description"`
	PubDate     string `xml:"pubDate"`
}

type atomFeed struct {
	Entries []atomEntry `xml:"entry"`
}

type atomEntry struct {
	Title   string     `xml:"title"`
	Link    atomLink   `xml:"link"`
	Summary string     `xml:"summary"`
	Updated string     `xml:"updated"`
	Content atomContent `xml:"content"`
}

type atomLink struct {
	Href string `xml:"href,attr"`
}

type atomContent struct {
	Value string `xml:",chardata"`
}

func looksLikeFeed(body string) bool {
	lower := strings.ToLower(body)
	return strings.Contains(lower, "<rss") || strings.Contains(lower, "<feed")
}

func parseFeed(body string, sourceLabel string) []Article {
	if strings.Contains(strings.ToLower(body), "<feed") {
		return parseAtom(body, sourceLabel)
	}
	return parseRSS(body, sourceLabel)
}

func parseRSS(body string, sourceLabel string) []Article {
	var feed rssFeed
	if err := xml.Unmarshal([]byte(body), &feed); err != nil {
		return parseRSSLoose(body, sourceLabel)
	}
	articles := make([]Article, 0, len(feed.Channel.Items))
	for _, item := range feed.Channel.Items {
		title := SanitizeDetail(item.Title, 240)
		link := strings.TrimSpace(StripTags(item.Link))
		if title == "" || link == "" {
			continue
		}
		resolved := PreferredArticleURL(link, item.Description)
		detail := SanitizeDetail(item.Description, 280)
		articles = append(articles, Article{
			Title:       title,
			URL:         resolved,
			Detail:      detail,
			PublishedAt: strings.TrimSpace(item.PubDate),
		})
	}
	return articles
}

func parseAtom(body string, sourceLabel string) []Article {
	var feed atomFeed
	if err := xml.Unmarshal([]byte(body), &feed); err != nil {
		return parseRSSLoose(body, sourceLabel)
	}
	articles := make([]Article, 0, len(feed.Entries))
	for _, entry := range feed.Entries {
		title := SanitizeDetail(entry.Title, 240)
		link := strings.TrimSpace(entry.Link.Href)
		if title == "" || link == "" {
			continue
		}
		snippet := entry.Summary
		if snippet == "" {
			snippet = entry.Content.Value
		}
		resolved := PreferredArticleURL(link, snippet)
		detail := SanitizeDetail(snippet, 280)
		articles = append(articles, Article{
			Title:       title,
			URL:         resolved,
			Detail:      detail,
			PublishedAt: strings.TrimSpace(entry.Updated),
		})
	}
	return articles
}

func parseRSSLoose(body string, sourceLabel string) []Article {
	_ = sourceLabel
	blocks := splitBlocks(body, "<item", "</item>")
	blocks = append(blocks, splitBlocks(body, "<entry", "</entry>")...)
	articles := make([]Article, 0, len(blocks))
	for _, block := range blocks {
		title := firstTag(block, "title")
		link := firstTag(block, "link")
		if link == "" {
			link = firstAttr(block, "link", "href")
		}
		if link == "" {
			link = firstTag(block, "guid")
		}
		description := firstTag(block, "description")
		if description == "" {
			description = firstTag(block, "summary")
		}
		if description == "" {
			description = firstTag(block, "content")
		}
		cleanTitle := SanitizeDetail(title, 240)
		cleanLink := strings.TrimSpace(StripTags(link))
		if cleanTitle == "" || cleanLink == "" {
			continue
		}
		resolved := PreferredArticleURL(cleanLink, description)
		detail := SanitizeDetail(description, 280)
		articles = append(articles, Article{
			Title:       cleanTitle,
			URL:         resolved,
			Detail:      detail,
			PublishedAt: strings.TrimSpace(firstTag(block, "pubDate")),
		})
	}
	return articles
}

func splitBlocks(body string, startToken string, endToken string) []string {
	lower := strings.ToLower(body)
	startLower := strings.ToLower(startToken)
	endLower := strings.ToLower(endToken)
	var blocks []string
	idx := 0
	for {
		start := strings.Index(lower[idx:], startLower)
		if start < 0 {
			break
		}
		start += idx
		end := strings.Index(lower[start:], endLower)
		if end < 0 {
			break
		}
		end += start + len(endToken)
		blocks = append(blocks, body[start:end])
		idx = end
	}
	return blocks
}

func firstTag(block string, name string) string {
	open := "<" + strings.ToLower(name)
	lower := strings.ToLower(block)
	start := strings.Index(lower, open)
	if start < 0 {
		return ""
	}
	closeTag := strings.Index(block[start:], ">")
	if closeTag < 0 {
		return ""
	}
	contentStart := start + closeTag + 1
	endToken := "</" + strings.ToLower(name) + ">"
	end := strings.Index(strings.ToLower(block[contentStart:]), endToken)
	if end < 0 {
		return ""
	}
	return block[contentStart : contentStart+end]
}

func firstAttr(block string, tagName string, attr string) string {
	open := "<" + strings.ToLower(tagName)
	lower := strings.ToLower(block)
	start := strings.Index(lower, open)
	if start < 0 {
		return ""
	}
	closeTag := strings.Index(block[start:], ">")
	if closeTag < 0 {
		return ""
	}
	tag := block[start : start+closeTag+1]
	pattern := regexp.MustCompile(`(?i)` + attr + `\s*=\s*"([^"]+)"`)
	match := pattern.FindStringSubmatch(tag)
	if len(match) < 2 {
		return ""
	}
	return match[1]
}
