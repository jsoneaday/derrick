package newsreader

import "testing"

func TestValidateRequiresSources(t *testing.T) {
	_, err := Validate(Request{Mode: ModeRSS, Sources: []Source{}})
	if err == nil {
		t.Fatal("expected validation error")
	}
}

func TestParseFeedReadsRSSItem(t *testing.T) {
	rss := `<?xml version="1.0"?><rss><channel>
	<item><title>Hello</title><link>https://example.com/a</link><description>Body</description></item>
	</channel></rss>`
	articles := parseFeed(rss, "Example")
	if len(articles) != 1 {
		t.Fatalf("expected 1 article, got %d", len(articles))
	}
	if articles[0].Title != "Hello" {
		t.Fatalf("unexpected title %q", articles[0].Title)
	}
}

func TestCanonicalFetchURLRewritesGoogleNewsHomepage(t *testing.T) {
	got := CanonicalFetchURL("https://news.google.com/", "tech news")
	if got == "https://news.google.com/" {
		t.Fatalf("expected RSS rewrite, got %q", got)
	}
}
