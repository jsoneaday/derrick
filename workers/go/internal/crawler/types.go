package crawler

// Wire types mirror worker-product.schema.json (web_crawler_result) in Structure Contract.

const (
	DefaultMaxPages        = 10
	MaximumMaxPages        = 100
	DefaultMaxDepth        = 2
	MaximumMaxDepth        = 5
	DefaultTimeoutSeconds  = 120
	MaximumTimeoutSeconds  = 900
	MaximumPageBytes       = 1_048_576
	MaximumTotalBytes      = 10 * 1_048_576
	MaximumLinksPerPage    = 200
	MaximumQueuedURLs      = 400
	MaximumExtractedText   = 12_000
	MaximumOutputChars     = 500_000
	MaximumRedirectsPerPage = 5
	MinRequestDelayMS      = 150
)

type Request struct {
	StartURL       string   `json:"start_url"`
	Goal           string   `json:"goal"`
	MaxPages       int      `json:"max_pages"`
	MaxDepth       int      `json:"max_depth"`
	TimeoutSeconds int      `json:"timeout_seconds"`
	AllowedHosts   []string `json:"allowed_hosts,omitempty"`
}

type Page struct {
	URL         string  `json:"url"`
	Depth       int     `json:"depth"`
	StatusCode  int     `json:"status_code"`
	ContentType *string `json:"content_type,omitempty"`
	Title       string  `json:"title"`
	Text        string  `json:"text"`
	LinksFound  int     `json:"links_found"`
}

type StopReason string

const (
	StopCompleted  StopReason = "completed"
	StopMaxPages   StopReason = "max_pages"
	StopMaxDepth   StopReason = "max_depth"
	StopTimeout    StopReason = "timeout"
	StopTotalBytes StopReason = "total_bytes"
	StopQueueLimit StopReason = "queue_limit"
	StopCancelled  StopReason = "cancelled"
	StopBlocked    StopReason = "blocked"
)

type Result struct {
	OK            bool       `json:"ok"`
	StartURL      string     `json:"start_url"`
	Pages         []Page     `json:"pages"`
	StopReason    StopReason `json:"stop_reason"`
	RequestsMade  int        `json:"requests_made"`
	BytesRead     int        `json:"bytes_read"`
	Truncated     bool       `json:"truncated"`
	Diagnostics   []string   `json:"diagnostics"`
}

type ProxyConfig struct {
	Host  string
	Port  int
	Token string
}
