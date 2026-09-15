package search

import "strings"

var blockedPatterns = []struct {
	substr string
	reason string
}{
	{"ddos", "distributed denial-of-service behavior is not allowed."},
	{"denial of service", "denial-of-service behavior is not allowed."},
	{"dos attack", "denial-of-service behavior is not allowed."},
	{"flood", "flooding a website is not allowed."},
	{"port scan", "port scanning is not a web search."},
	{"brute force", "brute-force activity is not allowed."},
}

func Validate(req Request) (ValidatedRequest, error) {
	query := strings.TrimSpace(req.Query)
	if query == "" {
		return ValidatedRequest{}, validationError("A search query is required.")
	}
	if len(query) > MaximumQueryChars {
		return ValidatedRequest{}, validationError("The search query is too long.")
	}
	if reason := MaliciousQueryReason(query); reason != "" {
		return ValidatedRequest{}, validationError("Search blocked: " + reason)
	}
	maxResults := req.MaxResults
	if maxResults == 0 {
		maxResults = DefaultMaxResults
	}
	if maxResults < 1 || maxResults > MaximumMaxResults {
		return ValidatedRequest{}, validationError("max_results must be between 1 and 10.")
	}
	timeout := req.TimeoutSeconds
	if timeout == 0 {
		timeout = DefaultTimeoutSeconds
	}
	if timeout < 1 || timeout > MaximumTimeoutSeconds {
		return ValidatedRequest{}, validationError("timeout_seconds must be between 1 and 60.")
	}
	return ValidatedRequest{
		Query:          query,
		MaxResults:     maxResults,
		TimeoutSeconds: timeout,
	}, nil
}

func MaliciousQueryReason(query string) string {
	normalized := strings.ReplaceAll(strings.ReplaceAll(strings.ToLower(query), "-", " "), "_", " ")
	for _, p := range blockedPatterns {
		if strings.Contains(normalized, p.substr) {
			return p.reason
		}
	}
	return ""
}

type validationError string

func (e validationError) Error() string { return string(e) }
