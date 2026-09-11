package newsreader

import (
	"net/url"
	"strings"

	"github.com/PuerkitoBio/goquery"
)

func parseHTMLArticles(body string, pageURL string, sourceLabel string) []Article {
	doc, err := goquery.NewDocumentFromReader(strings.NewReader(body))
	if err != nil {
		return nil
	}
	articles := make([]Article, 0, 32)
	seen := map[string]bool{}

	add := func(title string, href string, detail string) {
		title = SanitizeDetail(title, 240)
		href = strings.TrimSpace(href)
		if title == "" || href == "" || seen[href] {
			return
		}
		seen[href] = true
		articles = append(articles, Article{
			Title:  title,
			URL:    href,
			Detail: SanitizeDetail(detail, 280),
		})
	}

	doc.Find("article a[href]").Each(func(_ int, sel *goquery.Selection) {
		href := resolveHref(pageURL, sel.AttrOr("href", ""))
		if href == "" {
			return
		}
		title := strings.TrimSpace(sel.Text())
		if title == "" {
			title = strings.TrimSpace(sel.Closest("article").Find("h1,h2,h3").First().Text())
		}
		add(title, href, sel.Closest("article").Text())
	})

	doc.Find("h1 a[href], h2 a[href], h3 a[href]").Each(func(_ int, sel *goquery.Selection) {
		href := resolveHref(pageURL, sel.AttrOr("href", ""))
		title := strings.TrimSpace(sel.Text())
		add(title, href, sel.Parent().Text())
	})

	if len(articles) == 0 {
		doc.Find("a[href]").Each(func(_ int, sel *goquery.Selection) {
			href := resolveHref(pageURL, sel.AttrOr("href", ""))
			title := strings.TrimSpace(sel.Text())
			if len(title) < 12 || len(title) > 200 {
				return
			}
			add(title, href, "")
		})
	}

	if len(articles) == 0 {
		title := strings.TrimSpace(doc.Find("title").First().Text())
		if title != "" {
			add(title, pageURL, doc.Find("meta[name=description]").AttrOr("content", ""))
		}
	}
	return articles
}

func resolveHref(pageURL string, href string) string {
	href = strings.TrimSpace(href)
	if href == "" || strings.HasPrefix(href, "#") || strings.HasPrefix(strings.ToLower(href), "javascript:") {
		return ""
	}
	base, err := url.Parse(pageURL)
	if err != nil {
		return href
	}
	ref, err := url.Parse(href)
	if err != nil {
		return ""
	}
	resolved := base.ResolveReference(ref)
	if resolved.Scheme != "http" && resolved.Scheme != "https" {
		return ""
	}
	return resolved.String()
}
