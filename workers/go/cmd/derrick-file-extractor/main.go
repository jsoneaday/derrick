package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"

	"github.com/jsoneaday/derrick/workers/internal/contract"
	"github.com/jsoneaday/derrick/workers/internal/extractor"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		writeResult(extractor.Result{
			OK:          false,
			Operation:   extractor.OperationExtract,
			Files:       []extractor.FileResult{},
			Diagnostics: []string{"File extractor input must be a valid JSON object."},
		}, 1)
		return
	}

	var req extractor.Request
	if err := json.Unmarshal(input, &req); err != nil {
		writeResult(extractor.Result{
			OK:          false,
			Operation:   extractor.OperationExtract,
			Files:       []extractor.FileResult{},
			Diagnostics: []string{"File extractor input must be a valid JSON object."},
		}, 1)
		return
	}

	result := extractor.Run(req, extractor.InputDirectory, extractor.OutputDirectory)
	code := 0
	if !result.OK {
		code = 1
	}
	writeResult(result, code)
}

func writeResult(result extractor.Result, code int) {
	payload, err := encodedExtractorResult(result)
	if err != nil {
		payload, _ = encodedExtractorResult(extractor.Result{
			OK:          false,
			Operation:   result.Operation,
			Files:       []extractor.FileResult{},
			Diagnostics: []string{"File extractor output violated worker contract."},
		})
		code = 1
	}
	_, _ = os.Stdout.Write(payload)
	os.Exit(code)
}

func encodedExtractorResult(result extractor.Result) ([]byte, error) {
	if result.Files == nil {
		result.Files = []extractor.FileResult{}
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
	if err := contract.ValidateFileExtractorResultJSON(data); err != nil {
		return nil, err
	}
	return append(data, '\n'), nil
}
