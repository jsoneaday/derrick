package crawler

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/PuerkitoBio/goquery"
)

type extractedPage struct {
	title  string
	text   string
	isHTML bool
}

func Run(ctx context.Context, req ValidatedRequest, proxy *ProxyConfig) Result {
	deadline := time.Now().Add(time.Duration(req.TimeoutSeconds) * time.Second)
	engine := &bfsEngine{
		req:      req,
		deadline: deadline,
		proxy:    proxy,
		client:   newHTTPClient(proxy),
	}
	return engine.run(ctx)
}

type queueItem struct {
	url   *url.URL
	depth int
}

type bfsEngine struct {
	req           ValidatedRequest
	deadline      time.Time
	proxy         *ProxyConfig
	client        *http.Client
	queue         []queueItem
	queuedKeys    map[string]bool
	visitedKeys   map[string]bool
	pageDepths    map[string]int
	pages         []Page
	pageIndexes   map[string]int
	diagnostics   []string
	stopReason    StopReason
	reachedMaxDepth bool
	requestsMade  int
	bytesRead     int
	lastRequestAt time.Time
}

func (e *bfsEngine) run(ctx context.Context) Result {
	startKey := URLKey(e.req.StartURL)
	e.queuedKeys = map[string]bool{startKey: true}
	e.visitedKeys = map[string]bool{}
	e.pageDepths = map[string]int{startKey: 0}
	e.pageIndexes = map[string]int{}
	e.queue = []queueItem{{url: e.req.StartURL, depth: 0}}

	for len(e.queue) > 0 && e.stopReason == "" {
		if time.Now().After(e.deadline) {
			e.stopReason = StopTimeout
			break
		}
		if len(e.pages) >= e.req.MaxPages {
			e.stopReason = StopMaxPages
			break
		}
		if ctx.Err() != nil {
			e.stopReason = StopCancelled
			break
		}

		next := e.queue[0]
		e.queue = e.queue[1:]
		key := URLKey(next.url)
		delete(e.queuedKeys, key)

		if !HostAllowed(e.req.AllowedHosts, next.url.Hostname()) || !IsHTTP(next.url) {
			continue
		}
		if e.visitedKeys[key] {
			continue
		}
		e.visitedKeys[key] = true
		if len(e.visitedKeys) > e.req.MaxPages {
			e.stopReason = StopMaxPages
			break
		}

		e.visit(ctx, next.url, next.depth)
	}

	if e.stopReason == "" {
		if e.reachedMaxDepth {
			e.stopReason = StopMaxDepth
		} else {
			e.stopReason = StopCompleted
		}
	}

	truncated := false
	totalChars := 0
	for i, p := range e.pages {
		totalChars += len(p.Text)
		if totalChars > MaximumOutputChars {
			truncated = true
			e.pages = e.pages[:i]
			break
		}
	}

	return Result{
		OK:           e.stopReason != StopBlocked && len(e.pages) > 0,
		StartURL:     e.req.StartURL.String(),
		Pages:        e.pages,
		StopReason:   e.stopReason,
		RequestsMade: e.requestsMade,
		BytesRead:    e.bytesRead,
		Truncated:    truncated,
		Diagnostics:  e.diagnostics,
	}
}

func (e *bfsEngine) visit(ctx context.Context, pageURL *url.URL, depth int) {
	if e.stopReason != "" || time.Now().After(e.deadline) {
		return
	}

	normalized := NormalizeURL(pageURL)
	e.requestsMade++
	body, status, contentType, finalURL, err := e.fetch(ctx, normalized)
	if err != nil {
		e.diagnostics = append(e.diagnostics, fmt.Sprintf("%s: %s", normalized.String(), err.Error()))
		return
	}

	e.bytesRead += len(body)
	if e.bytesRead > MaximumTotalBytes {
		e.stopReason = StopTotalBytes
		return
	}

	extracted := extractContent(body, contentType, finalURL)
	ct := contentType
	page := Page{
		URL:        finalURL.String(),
		Depth:      depth,
		StatusCode: status,
		ContentType: func() *string {
			if ct == "" {
				return nil
			}
			return &ct
		}(),
		Title: extracted.title,
		Text:  clipText(extracted.text, MaximumExtractedText),
	}
	e.pages = append(e.pages, page)
	sourceKey := URLKey(finalURL)
	e.pageIndexes[sourceKey] = len(e.pages) - 1
	e.pageDepths[sourceKey] = depth

	if !extracted.isHTML {
		return
	}

	links := parseLinks(body, finalURL)
	accepted := e.enqueueLinks(sourceKey, links)
	idx := e.pageIndexes[sourceKey]
	e.pages[idx].LinksFound = accepted
}

func (e *bfsEngine) enqueueLinks(sourceKey string, links []*url.URL) int {
	sourceDepth := e.pageDepths[sourceKey]
	accepted := 0
	for _, link := range links {
		if e.stopReason != "" {
			break
		}
		if len(links) > MaximumLinksPerPage && accepted >= MaximumLinksPerPage {
			break
		}
		normalized := NormalizeURL(link)
		key := URLKey(normalized)
		if !HostAllowed(e.req.AllowedHosts, normalized.Hostname()) || !IsHTTP(normalized) {
			continue
		}
		if e.visitedKeys[key] || e.queuedKeys[key] {
			continue
		}
		nextDepth := sourceDepth + 1
		if nextDepth > e.req.MaxDepth {
			e.reachedMaxDepth = true
			continue
		}
		if len(e.queue) >= MaximumQueuedURLs {
			e.stopReason = StopQueueLimit
			break
		}
		e.queuedKeys[key] = true
		e.pageDepths[key] = nextDepth
		e.queue = append(e.queue, queueItem{url: normalized, depth: nextDepth})
		accepted++
	}
	return accepted
}

func newHTTPClient(proxy *ProxyConfig) *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	if proxy != nil && proxy.Host != "" {
		proxyURL, _ := url.Parse(fmt.Sprintf("http://%s:%d", proxy.Host, proxy.Port))
		transport.Proxy = http.ProxyURL(proxyURL)
		if proxy.Token != "" {
			transport.ProxyConnectHeader = http.Header{
				"X-Derrick-Crawler-Token": []string{proxy.Token},
			}
		}
	}
	return &http.Client{
		Transport: transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
		Timeout: 20 * time.Second,
	}
}

func (e *bfsEngine) fetch(ctx context.Context, start *url.URL) (body string, status int, contentType string, final *url.URL, err error) {
	e.waitForSpacing()
	current := start
	redirected := map[string]bool{URLKey(start): true}

	for i := 0; i <= MaximumRedirectsPerPage; i++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, current.String(), nil)
		if err != nil {
			return "", 0, "", start, err
		}
		req.Header.Set("User-Agent", "DerrickWebCrawler/1")
		req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
		req.Header.Set("Accept-Language", "en-US,en;q=0.9")
		req.Header.Set("Accept-Encoding", "identity")
		if e.proxy != nil && e.proxy.Token != "" {
			req.Header.Set("X-Derrick-Crawler-Token", e.proxy.Token)
		}

		resp, err := e.client.Do(req)
		if err != nil {
			return "", 0, "", start, err
		}
		limited := io.LimitReader(resp.Body, int64(MaximumPageBytes))
		data, err := io.ReadAll(limited)
		resp.Body.Close()
		if err != nil {
			return "", 0, "", start, err
		}
		text := string(data)
		ct := resp.Header.Get("Content-Type")

		if resp.StatusCode < 300 || resp.StatusCode >= 400 {
			return text, resp.StatusCode, ct, current, nil
		}

		location := resp.Header.Get("Location")
		if location == "" {
			return text, resp.StatusCode, ct, current, nil
		}
		redirectURL, err := url.Parse(location)
		if err != nil {
			return "", 0, "", start, fmt.Errorf("redirect left the start URL origin")
		}
		redirectURL = current.ResolveReference(redirectURL)
		if !IsHTTP(redirectURL) {
			return "", 0, "", start, fmt.Errorf("redirect left the start URL origin")
		}
		host := strings.ToLower(strings.TrimSpace(redirectURL.Hostname()))
		if host == "" {
			return "", 0, "", start, fmt.Errorf("redirect left the start URL origin")
		}
		e.req.AllowedHosts[host] = true
		normalized := NormalizeURL(redirectURL)
		key := URLKey(normalized)
		if redirected[key] {
			return "", 0, "", start, fmt.Errorf("redirect loop detected")
		}
		redirected[key] = true
		current = normalized
		e.waitForSpacing()
	}
	return "", 0, "", start, fmt.Errorf("redirect limit reached")
}

func (e *bfsEngine) waitForSpacing() {
	if e.lastRequestAt.IsZero() {
		e.lastRequestAt = time.Now()
		return
	}
	elapsed := time.Since(e.lastRequestAt)
	minimum := time.Duration(MinRequestDelayMS) * time.Millisecond
	if elapsed < minimum {
		time.Sleep(minimum - elapsed)
	}
	e.lastRequestAt = time.Now()
}

func extractContent(body string, contentType string, base *url.URL) extractedPage {
	lower := strings.ToLower(contentType)
	if strings.Contains(lower, "html") || strings.Contains(lower, "xhtml") {
		return extractHTML(body)
	}
	prefix := body
	if len(prefix) > MaximumExtractedText {
		prefix = prefix[:MaximumExtractedText]
	}
	return extractedPage{title: "", text: prefix, isHTML: false}
}

func extractHTML(body string) extractedPage {
	doc, err := goquery.NewDocumentFromReader(strings.NewReader(body))
	if err != nil {
		return extractedPage{text: body, isHTML: true}
	}
	doc.Find("script, style, noscript, template, svg").Remove()
	title := strings.TrimSpace(doc.Find("title").First().Text())
	text := strings.TrimSpace(doc.Find("body").Text())
	if text == "" {
		text = strings.TrimSpace(doc.Text())
	}
	return extractedPage{title: title, text: text, isHTML: true}
}

func parseLinks(body string, base *url.URL) []*url.URL {
	doc, err := goquery.NewDocumentFromReader(strings.NewReader(body))
	if err != nil {
		return nil
	}
	var links []*url.URL
	seen := map[string]bool{}
	doc.Find("a[href]").Each(func(_ int, s *goquery.Selection) {
		href, ok := s.Attr("href")
		if !ok || strings.TrimSpace(href) == "" {
			return
		}
		parsed, err := url.Parse(href)
		if err != nil {
			return
		}
		resolved := base.ResolveReference(parsed)
		resolved.Fragment = ""
		resolved.RawFragment = ""
		resolved = NormalizeURL(resolved)
		key := URLKey(resolved)
		if seen[key] {
			return
		}
		seen[key] = true
		links = append(links, resolved)
	})
	return links
}

func clipText(text string, limit int) string {
	if len(text) <= limit {
		return text
	}
	return text[:limit]
}
