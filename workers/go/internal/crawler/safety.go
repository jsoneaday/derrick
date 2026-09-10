package crawler

import "strings"

var blockedPatterns = []struct {
	substr string
	reason string
}{
	{"ddos", "distributed denial-of-service behavior is not allowed."},
	{"denial of service", "denial-of-service behavior is not allowed."},
	{"dos attack", "denial-of-service behavior is not allowed."},
	{"flood", "flooding a website is not allowed."},
	{"hammer", "repeatedly hammering a website is not allowed."},
	{"stress test", "load or stress testing a third-party website is not allowed."},
	{"load test", "load or stress testing a third-party website is not allowed."},
	{"port scan", "port scanning is not a web crawl."},
	{"brute force", "brute-force activity is not allowed."},
	{"infinite loop", "unbounded or infinite crawling is not allowed."},
	{"loop forever", "unbounded or infinite crawling is not allowed."},
	{"crawl forever", "unbounded or infinite crawling is not allowed."},
	{"never stop crawling", "unbounded or infinite crawling is not allowed."},
	{"unbounded crawl", "unbounded or infinite crawling is not allowed."},
}

func MaliciousGoalReason(goal string) string {
	normalized := strings.ReplaceAll(strings.ReplaceAll(strings.ToLower(goal), "-", " "), "_", " ")
	for _, p := range blockedPatterns {
		if strings.Contains(normalized, p.substr) {
			return p.reason
		}
	}
	return ""
}
