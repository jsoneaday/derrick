package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"strconv"

	"github.com/jsoneaday/derrick/workers/internal/contract"
	"github.com/jsoneaday/derrick/workers/internal/newsreader"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		writeResult(blockedResult(newsreader.ModeRSS, "News reader input must be a valid JSON object."))
		return
	}

	var req newsreader.Request
	if err := json.Unmarshal(input, &req); err != nil {
		writeResult(blockedResult(newsreader.ModeRSS, "News reader input must be a valid JSON object."))
		return
	}

	validated, err := newsreader.Validate(req)
	if err != nil {
		writeResult(blockedResult(req.Mode, err.Error()))
		return
	}

	result := newsreader.Run(context.Background(), validated, readProxy())
	writeResult(result)
}

func readProxy() *newsreader.ProxyConfig {
	host := os.Getenv("DERRICK_EGRESS_PROXY_HOST")
	portStr := os.Getenv("DERRICK_EGRESS_PROXY_PORT")
	token := os.Getenv("DERRICK_EGRESS_PROXY_TOKEN")
	if host == "" && portStr == "" && token == "" {
		return nil
	}
	port, _ := strconv.Atoi(portStr)
	return &newsreader.ProxyConfig{Host: host, Port: port, Token: token}
}

func blockedResult(mode newsreader.Mode, message string) newsreader.Result {
	if mode == "" {
		mode = newsreader.ModeRSS
	}
	return newsreader.Result{
		OK:          false,
		Mode:        mode,
		Articles:    []newsreader.Article{},
		Diagnostics: []string{message},
	}
}

func writeResult(result newsreader.Result) {
	payload, err := encodedResult(result)
	if err != nil {
		writeEncodedResult(blockedResult(result.Mode, "News reader output violated worker contract."))
		return
	}
	_, _ = os.Stdout.Write(payload)
}

func encodedResult(result newsreader.Result) ([]byte, error) {
	if result.Articles == nil {
		result.Articles = []newsreader.Article{}
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
	if err := contract.ValidateNewsReaderResultJSON(data); err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}

func writeEncodedResult(result newsreader.Result) {
	payload, err := encodedResult(result)
	if err != nil {
		fallback := blockedResult(newsreader.ModeRSS, "News reader failed to produce schema-compliant output.")
		payload, _ = encodedResult(fallback)
	}
	_, _ = os.Stdout.Write(payload)
}
