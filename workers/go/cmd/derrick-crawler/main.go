package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"strconv"

	"github.com/jsoneaday/derrick/workers/internal/contract"
	"github.com/jsoneaday/derrick/workers/internal/crawler"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		writeResult(blockedResult("", "Crawler input must be a valid JSON object."))
		return
	}

	var req crawler.Request
	if err := json.Unmarshal(input, &req); err != nil {
		writeResult(blockedResult("", "Crawler input must be a valid JSON object."))
		return
	}

	validated, err := crawler.Validate(req)
	if err != nil {
		writeResult(blockedResult(req.StartURL, err.Error()))
		return
	}

	proxy := readProxy()
	ctx := context.Background()
	result := crawler.Run(ctx, validated, proxy)
	if len(result.Pages) == 0 && result.StopReason == crawler.StopCompleted {
		result.OK = false
	}
	if len(result.Pages) > 0 {
		result.OK = true
	}
	writeResult(result)
}

func readProxy() *crawler.ProxyConfig {
	host := os.Getenv("DERRICK_EGRESS_PROXY_HOST")
	portStr := os.Getenv("DERRICK_EGRESS_PROXY_PORT")
	token := os.Getenv("DERRICK_EGRESS_PROXY_TOKEN")
	if host == "" && portStr == "" && token == "" {
		return nil
	}
	port, _ := strconv.Atoi(portStr)
	return &crawler.ProxyConfig{Host: host, Port: port, Token: token}
}

func blockedResult(startURL string, message string) crawler.Result {
	return crawler.Result{
		OK:         false,
		StartURL:   startURL,
		Pages:      []crawler.Page{},
		StopReason: crawler.StopBlocked,
		Diagnostics: []string{message},
	}
}

func writeResult(result crawler.Result) {
	payload, err := encodedCrawlerResult(result)
	if err != nil {
		writeEncodedResult(blockedResult(result.StartURL, "Crawler output violated worker contract."))
		return
	}
	_, _ = os.Stdout.Write(payload)
}

func encodedCrawlerResult(result crawler.Result) ([]byte, error) {
	if result.Pages == nil {
		result.Pages = []crawler.Page{}
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
	if err := contract.ValidateWebCrawlerResultJSON(data); err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

func writeEncodedResult(result crawler.Result) {
	payload, err := encodedCrawlerResult(result)
	if err != nil {
		fallback := blockedResult("", "Crawler failed to produce schema-compliant output.")
		payload, _ = encodedCrawlerResult(fallback)
	}
	_, _ = os.Stdout.Write(payload)
}
