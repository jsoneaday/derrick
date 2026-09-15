package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"strconv"

	"github.com/jsoneaday/derrick/workers/internal/contract"
	"github.com/jsoneaday/derrick/workers/internal/search"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		writeResult(blockedResult("", "Search input must be a valid JSON object."))
		return
	}

	var req search.Request
	if err := json.Unmarshal(input, &req); err != nil {
		writeResult(blockedResult("", "Search input must be a valid JSON object."))
		return
	}

	validated, err := search.Validate(req)
	if err != nil {
		writeResult(blockedResult(req.Query, err.Error()))
		return
	}

	result := search.Run(context.Background(), validated, readProxy())
	writeResult(result)
}

func readProxy() *search.ProxyConfig {
	host := os.Getenv("DERRICK_EGRESS_PROXY_HOST")
	portStr := os.Getenv("DERRICK_EGRESS_PROXY_PORT")
	token := os.Getenv("DERRICK_EGRESS_PROXY_TOKEN")
	if host == "" && portStr == "" && token == "" {
		return nil
	}
	port, _ := strconv.Atoi(portStr)
	return &search.ProxyConfig{Host: host, Port: port, Token: token}
}

func blockedResult(query string, message string) search.Result {
	return search.Result{
		OK:          false,
		Query:       query,
		Hits:        []search.Hit{},
		Diagnostics: []string{message},
	}
}

func writeResult(result search.Result) {
	payload, err := encodedSearchResult(result)
	if err != nil {
		writeEncodedResult(blockedResult(result.Query, "Search output violated worker contract."))
		return
	}
	_, _ = os.Stdout.Write(payload)
}

func encodedSearchResult(result search.Result) ([]byte, error) {
	if result.Hits == nil {
		result.Hits = []search.Hit{}
	}
	if result.Diagnostics == nil {
		result.Diagnostics = []string{}
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(result); err != nil {
		return nil, err
	}
	data := bytes.TrimSpace(buf.Bytes())
	if err := contract.ValidateWebSearchResultJSON(data); err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

func writeEncodedResult(result search.Result) {
	payload, err := encodedSearchResult(result)
	if err != nil {
		fallback := blockedResult("", "Search failed to produce schema-compliant output.")
		payload, _ = encodedSearchResult(fallback)
	}
	_, _ = os.Stdout.Write(payload)
}
