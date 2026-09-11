package newsreader

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

func fetchSource(
	ctx context.Context,
	client *http.Client,
	source Source,
	mode Mode,
	contextHint string,
) ([]Article, []string) {
	fetchURL := CanonicalFetchURL(source.URL, contextHint)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fetchURL, nil)
	if err != nil {
		return nil, []string{fmt.Sprintf("%s: %v", source.Label, err)}
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (compatible; DerrickNewsReader/1.0)")
	req.Header.Set("Accept", "application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8")

	resp, err := client.Do(req)
	if err != nil {
		return nil, []string{fmt.Sprintf("Could not read %s: %v", source.URL, err)}
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 400 {
		return nil, []string{fmt.Sprintf("Could not read %s: HTTP %d", source.URL, resp.StatusCode)}
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return nil, []string{fmt.Sprintf("Could not read %s: %v", source.URL, err)}
	}
	text := string(body)
	if looksLikeFeed(text) {
		articles := parseFeed(text, source.Label)
		if len(articles) > 0 {
			return articles, nil
		}
	}
	if mode == ModeRSS {
		articles := parseFeed(text, source.Label)
		if len(articles) > 0 {
			return articles, nil
		}
		return nil, []string{fmt.Sprintf("No articles were found in %s", source.URL)}
	}
	if mode == ModeList || mode == ModeSummary {
		articles := parseHTMLArticles(text, fetchURL, source.Label)
		if len(articles) > 0 {
			return articles, nil
		}
		return nil, []string{fmt.Sprintf("No articles were found on %s", source.URL)}
	}
	return nil, []string{fmt.Sprintf("No articles were found in %s", source.URL)}
}

func newHTTPClient(proxy *ProxyConfig) *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	return &http.Client{
		Timeout:   time.Duration(DefaultTimeoutSeconds) * time.Second,
		Transport: transport,
	}
}

func filterTopics(articles []Article, topics []string) []Article {
	needles := make([]string, 0, len(topics))
	for _, topic := range topics {
		trimmed := strings.ToLower(strings.TrimSpace(topic))
		if trimmed != "" {
			needles = append(needles, trimmed)
		}
	}
	if len(needles) == 0 {
		return articles
	}
	matched := make([]Article, 0, len(articles))
	unmatched := make([]Article, 0, len(articles))
	for _, article := range articles {
		hay := strings.ToLower(article.Title + " " + article.Detail)
		if topicMatches(hay, needles) {
			matched = append(matched, article)
		} else {
			unmatched = append(unmatched, article)
		}
	}
	if len(matched) == 0 {
		return articles
	}
	// Prefer topic matches, but keep other articles when filtering would drop too many
	// (for example WSJ headlines that do not literally contain "tech").
	if len(matched) < 3 && len(unmatched) > 0 {
		out := make([]Article, 0, len(articles))
		out = append(out, matched...)
		out = append(out, unmatched...)
		return out
	}
	return matched
}

func topicMatches(hay string, needles []string) bool {
	for _, needle := range needles {
		if strings.Contains(hay, needle) {
			return true
		}
	}
	return false
}

func uniqueArticles(articles []Article) []Article {
	seen := map[string]bool{}
	out := make([]Article, 0, len(articles))
	for _, article := range articles {
		if seen[article.URL] {
			continue
		}
		seen[article.URL] = true
		out = append(out, article)
	}
	return out
}
