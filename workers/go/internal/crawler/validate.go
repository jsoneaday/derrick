package crawler

import (
	"net/url"
	"strings"
)

type ValidatedRequest struct {
	StartURL       *url.URL
	Goal           string
	MaxPages       int
	MaxDepth       int
	TimeoutSeconds int
	AllowedHosts   map[string]bool
}

func Validate(req Request) (ValidatedRequest, error) {
	goal := strings.TrimSpace(req.Goal)
	if goal == "" {
		return ValidatedRequest{}, validationError("A crawl goal is required.")
	}
	if len(goal) > 2000 {
		return ValidatedRequest{}, validationError("The crawl goal is too long.")
	}
	if reason := MaliciousGoalReason(goal); reason != "" {
		return ValidatedRequest{}, validationError("Crawl blocked: " + reason)
	}

	maxPages := req.MaxPages
	if maxPages == 0 {
		maxPages = DefaultMaxPages
	}
	if maxPages < 1 || maxPages > MaximumMaxPages {
		return ValidatedRequest{}, validationError("max_pages must be between 1 and 100.")
	}

	maxDepth := req.MaxDepth
	if maxDepth == 0 {
		maxDepth = DefaultMaxDepth
	}
	if maxDepth < 0 || maxDepth > MaximumMaxDepth {
		return ValidatedRequest{}, validationError("max_depth must be between 0 and 5.")
	}

	timeout := req.TimeoutSeconds
	if timeout == 0 {
		timeout = DefaultTimeoutSeconds
	}
	if timeout < 1 || timeout > MaximumTimeoutSeconds {
		return ValidatedRequest{}, validationError("timeout_seconds must be between 1 and 900.")
	}

	start, err := ParseStartURL(req.StartURL)
	if err != nil {
		return ValidatedRequest{}, err
	}

	return ValidatedRequest{
		StartURL:       start,
		Goal:           goal,
		MaxPages:       maxPages,
		MaxDepth:       maxDepth,
		TimeoutSeconds: timeout,
		AllowedHosts:   ResolvedAllowedHosts(start.Hostname(), req.AllowedHosts),
	}, nil
}
