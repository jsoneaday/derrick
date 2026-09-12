package contract

import "testing"

func TestValidateHopEventAndEnvelopeList(t *testing.T) {
	hop := []byte(`{"kind":"manual"}`)
	if err := ValidateHopEventJSON(hop); err != nil {
		t.Fatalf("hop event: %v", err)
	}
	env := []byte(`[{"verb":"result.emit","summary":"ok"}]`)
	if err := ValidateEnvelopeListJSON(env); err != nil {
		t.Fatalf("envelope list: %v", err)
	}
}

func TestValidateEnvelopeListRejectsNestedAlias(t *testing.T) {
	env := []byte(`[{"verb":"result.emit","result":{"emit":{"content":"x"}}}]`)
	if err := ValidateEnvelopeListJSON(env); err == nil {
		t.Fatal("expected rejection")
	}
}

func TestValidateWebCrawlerResultAcceptsEmptyDiagnosticsArray(t *testing.T) {
	payload := []byte(`{"ok":true,"start_url":"https://example.com/","pages":[],"stop_reason":"completed","requests_made":0,"bytes_read":0,"truncated":false,"diagnostics":[]}`)
	if err := ValidateWebCrawlerResultJSON(payload); err != nil {
		t.Fatalf("web crawler result: %v", err)
	}
}

func TestValidateWebCrawlerResultRejectsNullDiagnostics(t *testing.T) {
	payload := []byte(`{"ok":true,"start_url":"https://example.com/","pages":[],"stop_reason":"completed","requests_made":0,"bytes_read":0,"truncated":false,"diagnostics":null}`)
	if err := ValidateWebCrawlerResultJSON(payload); err == nil {
		t.Fatal("expected rejection for null diagnostics")
	}
}

func TestValidateFileExtractorResultAcceptsEmptyFilesArray(t *testing.T) {
	payload := []byte(`{"ok":true,"operation":"extract","files":[],"diagnostics":[]}`)
	if err := ValidateFileExtractorResultJSON(payload); err != nil {
		t.Fatalf("file extractor result: %v", err)
	}
}

func TestValidateFileExtractorResultRejectsNullFiles(t *testing.T) {
	payload := []byte(`{"ok":false,"operation":"extract","files":null,"diagnostics":[]}`)
	if err := ValidateFileExtractorResultJSON(payload); err == nil {
		t.Fatal("expected rejection for null files")
	}
}
