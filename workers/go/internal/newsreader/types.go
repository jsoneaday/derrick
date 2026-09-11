package newsreader

const (
	DefaultMaxCount       = 20
	MaximumMaxCount       = 50
	DefaultTimeoutSeconds = 120
	MaximumTimeoutSeconds = 300
)

type Mode string

const (
	ModeRSS     Mode = "rss"
	ModeList    Mode = "list"
	ModeSummary Mode = "summary"
)

type Source struct {
	Label string `json:"label"`
	URL   string `json:"url"`
}

type Request struct {
	Mode        Mode     `json:"mode"`
	Sources     []Source `json:"sources"`
	Topics      []string `json:"topics"`
	MaxCount    int      `json:"maxCount"`
	ContextHint string   `json:"contextHint,omitempty"`
}

type Article struct {
	Title       string `json:"title"`
	URL         string `json:"url"`
	Detail      string `json:"detail,omitempty"`
	PublishedAt string `json:"published_at,omitempty"`
}

type Result struct {
	OK          bool      `json:"ok"`
	Mode        Mode      `json:"mode"`
	Articles    []Article `json:"articles"`
	Diagnostics []string  `json:"diagnostics"`
}

type ProxyConfig struct {
	Host  string
	Port  int
	Token string
}
