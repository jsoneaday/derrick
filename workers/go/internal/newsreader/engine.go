package newsreader

import (
	"context"
)

func Run(ctx context.Context, req Request, proxy *ProxyConfig) Result {
	client := newHTTPClient(proxy)
	collected := make([]Article, 0, req.MaxCount)
	diagnostics := make([]string, 0)

	for _, source := range req.Sources {
		articles, notes := fetchSource(ctx, client, source, req.Mode, req.ContextHint)
		diagnostics = append(diagnostics, notes...)
		collected = append(collected, articles...)
	}

	filtered := filterTopics(collected, req.Topics)
	unique := uniqueArticles(filtered)
	if len(unique) > req.MaxCount {
		unique = unique[:req.MaxCount]
	}

	ok := len(unique) > 0
	if !ok && len(diagnostics) == 0 {
		diagnostics = append(diagnostics, "No articles were found for the configured sources.")
	}
	return Result{
		OK:          ok,
		Mode:        req.Mode,
		Articles:    unique,
		Diagnostics: diagnostics,
	}
}
