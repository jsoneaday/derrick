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

func TestCanonicalFetchURLUpgradesGeneralGoogleNewsRSSForTechHint(t *testing.T) {
	got := CanonicalFetchURL(
		"https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en",
		"tech-news Tech",
	)
	want := "https://news.google.com/rss/headlines/section/topic/TECHNOLOGY?hl=en-US&gl=US&ceid=US:en"
	if got != want {
		t.Fatalf("expected %q, got %q", want, got)
	}
}

func TestFilterTopicsKeepsUnmatchedArticlesWhenFewMatches(t *testing.T) {
	articles := []Article{
		{Title: "TechCrunch story", URL: "https://example.com/a"},
		{Title: "Wall Street earnings", URL: "https://example.com/b"},
		{Title: "Another market report", URL: "https://example.com/c"},
	}
	got := filterTopics(articles, []string{"Tech"})
	if len(got) != 3 {
		t.Fatalf("expected all articles when only one matches, got %d", len(got))
	}
	if got[0].Title != "TechCrunch story" {
		t.Fatalf("expected matched article first, got %q", got[0].Title)
	}
}
