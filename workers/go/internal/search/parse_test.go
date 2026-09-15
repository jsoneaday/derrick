package search

import "testing"

const htmlFixture = `
<div class="result results_links_deep web-result">
  <h2 class="result__title">
    <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdocs.slack.dev%2Fauthentication%2Ftokens">Slack tokens</a>
  </h2>
  <a class="result__snippet" href="#">How to create and use Slack API tokens.</a>
</div>
<div class="result result--ad">
  <h2 class="result__title">
    <a rel="nofollow" class="result__a" href="https://ads.example/spam">Buy tokens</a>
  </h2>
</div>
`

const liteFixture = `
<table>
<tr><td><a class="result-link" href="https://api.example.com/docs">Example API docs</a></td></tr>
<tr><td class="result-snippet">Official HTTP API reference.</td></tr>
</table>
`

func TestParseHTMLHitsUnwrapsDuckDuckGoRedirect(t *testing.T) {
	hits := parseHits(htmlFixture, 8)
	if len(hits) != 1 {
		t.Fatalf("hits=%d want 1", len(hits))
	}
	if hits[0].URL != "https://docs.slack.dev/authentication/tokens" {
		t.Fatalf("url=%s", hits[0].URL)
	}
	if hits[0].Title != "Slack tokens" {
		t.Fatalf("title=%s", hits[0].Title)
	}
	if hits[0].Snippet != "How to create and use Slack API tokens." {
		t.Fatalf("snippet=%s", hits[0].Snippet)
	}
}

func TestParseLiteHits(t *testing.T) {
	hits := parseHits(liteFixture, 8)
	if len(hits) != 1 {
		t.Fatalf("hits=%d want 1", len(hits))
	}
	if hits[0].URL != "https://api.example.com/docs" {
		t.Fatalf("url=%s", hits[0].URL)
	}
}

func TestValidateRejectsEmptyQuery(t *testing.T) {
	_, err := Validate(Request{Query: "  "})
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestValidateRejectsFloodQuery(t *testing.T) {
	_, err := Validate(Request{Query: "flood slack with requests"})
	if err == nil {
		t.Fatal("expected error")
	}
}
