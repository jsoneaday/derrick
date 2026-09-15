package search

// Wire types mirror worker-product.schema.json (web_search_result) in Structure Contract.

const (
	DefaultMaxResults      = 8
	MaximumMaxResults      = 10
	DefaultTimeoutSeconds  = 30
	MaximumTimeoutSeconds  = 60
	MaximumQueryChars      = 300
	MaximumPageBytes       = 1_048_576
	MaximumRedirects       = 5
	htmlSearchURL          = "https://html.duckduckgo.com/html/"
	liteSearchURL          = "https://lite.duckduckgo.com/lite/"
)

type Request struct {
	Query          string `json:"query"`
	MaxResults     int    `json:"max_results"`
	TimeoutSeconds int    `json:"timeout_seconds"`
}

type Hit struct {
	Title   string `json:"title"`
	URL     string `json:"url"`
	Snippet string `json:"snippet"`
}

type Result struct {
	OK          bool     `json:"ok"`
	Query       string   `json:"query"`
	Hits        []Hit    `json:"hits"`
	Diagnostics []string `json:"diagnostics"`
}

type ProxyConfig struct {
	Host  string
	Port  int
	Token string
}

type ValidatedRequest struct {
	Query          string
	MaxResults     int
	TimeoutSeconds int
}
