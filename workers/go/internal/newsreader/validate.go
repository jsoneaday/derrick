package newsreader

import (
	"fmt"
	"net/url"
	"strings"
)

func Validate(req Request) (Request, error) {
	out := req
	if out.Mode != ModeRSS && out.Mode != ModeList && out.Mode != ModeSummary {
		return out, fmt.Errorf("mode must be rss, list, or summary")
	}
	if len(out.Sources) == 0 {
		return out, fmt.Errorf("add at least one source URL")
	}
	if out.MaxCount <= 0 {
		out.MaxCount = DefaultMaxCount
	}
	if out.MaxCount > MaximumMaxCount {
		out.MaxCount = MaximumMaxCount
	}
	for i, source := range out.Sources {
		trimmed := strings.TrimSpace(source.URL)
		if trimmed == "" {
			return out, fmt.Errorf("source %d is missing a URL", i+1)
		}
		parsed, err := url.Parse(trimmed)
		if err != nil || parsed.Scheme != "http" && parsed.Scheme != "https" {
			return out, fmt.Errorf("source %d is not a usable web address", i+1)
		}
		out.Sources[i].URL = trimmed
		if strings.TrimSpace(out.Sources[i].Label) == "" {
			out.Sources[i].Label = parsed.Host
		}
	}
	return out, nil
}
