package search

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

func Run(ctx context.Context, req ValidatedRequest, proxy *ProxyConfig) Result {
	deadline := time.Now().Add(time.Duration(req.TimeoutSeconds) * time.Second)
	client := newHTTPClient(proxy)
	html, htmlErr := fetchSearch(ctx, client, proxy, htmlSearchURL, req.Query, deadline)
	hits := parseHits(html, req.MaxResults)
	diagnostics := []string{}
	if htmlErr != nil {
		diagnostics = append(diagnostics, htmlErr.Error())
	}
	if len(hits) == 0 {
		lite, liteErr := fetchSearch(ctx, client, proxy, liteSearchURL, req.Query, deadline)
		if liteErr != nil {
			diagnostics = append(diagnostics, liteErr.Error())
		}
		hits = parseHits(lite, req.MaxResults)
	}
	if hits == nil {
		hits = []Hit{}
	}
	if diagnostics == nil {
		diagnostics = []string{}
	}
	ok := len(hits) > 0
	if !ok && len(diagnostics) == 0 {
		diagnostics = []string{"DuckDuckGo returned no usable search results."}
	}
	return Result{
		OK:          ok,
		Query:       req.Query,
		Hits:        hits,
		Diagnostics: diagnostics,
	}
}

func fetchSearch(
	ctx context.Context,
	client *http.Client,
	proxy *ProxyConfig,
	endpoint string,
	query string,
	deadline time.Time,
) (string, error) {
	if time.Now().After(deadline) {
		return "", fmt.Errorf("search timed out")
	}
	form := url.Values{}
	form.Set("q", query)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", "DerrickWebSearch/1")
	req.Header.Set("Accept", "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8")
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	req.Header.Set("Accept-Encoding", "identity")
	if proxy != nil && proxy.Token != "" {
		req.Header.Set("X-Derrick-Crawler-Token", proxy.Token)
	}

	current := req
	for i := 0; i <= MaximumRedirects; i++ {
		if time.Now().After(deadline) {
			return "", fmt.Errorf("search timed out")
		}
		resp, err := client.Do(current)
		if err != nil {
			return "", err
		}
		limited := io.LimitReader(resp.Body, int64(MaximumPageBytes))
		data, readErr := io.ReadAll(limited)
		resp.Body.Close()
		if readErr != nil {
			return "", readErr
		}
		if resp.StatusCode >= 300 && resp.StatusCode < 400 {
			location := resp.Header.Get("Location")
			if location == "" {
				return "", fmt.Errorf("search redirect missing Location")
			}
			next, err := url.Parse(location)
			if err != nil {
				return "", err
			}
			next = current.URL.ResolveReference(next)
			if !isHTTPURL(next.String()) {
				return "", fmt.Errorf("search redirect was not HTTP")
			}
			current, err = http.NewRequestWithContext(ctx, http.MethodGet, next.String(), nil)
			if err != nil {
				return "", err
			}
			current.Header.Set("User-Agent", "DerrickWebSearch/1")
			if proxy != nil && proxy.Token != "" {
				current.Header.Set("X-Derrick-Crawler-Token", proxy.Token)
			}
			continue
		}
		if resp.StatusCode != http.StatusOK {
			return "", fmt.Errorf("DuckDuckGo returned HTTP %d", resp.StatusCode)
		}
		return string(data), nil
	}
	return "", fmt.Errorf("search followed too many redirects")
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
