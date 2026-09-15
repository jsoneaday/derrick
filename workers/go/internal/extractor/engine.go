package extractor

import (
	"archive/zip"
	"bytes"
	"encoding/xml"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/xuri/excelize/v2"
)

func Run(req Request, inputDir, outputDir string) Result {
	if len(req.Files) == 0 {
		return errorResult(req.Operation, "Choose at least one attached file.")
	}
	if len(req.Files) > MaximumFiles {
		return errorResult(req.Operation, fmt.Sprintf("You can process at most %d files.", MaximumFiles))
	}
	if req.OutputFormat == "" {
		req.OutputFormat = FormatMarkdown
	}
	if req.Operation == "" {
		req.Operation = OperationExtract
	}

	var files []FileResult
	var diagnostics []string
	previewBudget := MaximumTotalPreviewChars

	for _, name := range req.Files {
		safeName, err := validatedFilename(name)
		if err != nil {
			files = append(files, FileResult{
				InputName: name,
				Kind:      kindFor(name),
				Error:     strPtr(err.Error()),
			})
			continue
		}
		inputPath := filepath.Join(inputDir, safeName)
		if _, err := os.Stat(inputPath); err != nil {
			msg := fmt.Sprintf("%s was not found in /data/in.", safeName)
			files = append(files, FileResult{
				InputName: safeName,
				Kind:      kindFor(safeName),
				Error:     &msg,
			})
			continue
		}

		processed, err := process(inputPath, req.Operation, req.OutputFormat)
		if err != nil {
			msg := err.Error()
			diagnostics = append(diagnostics, msg)
			files = append(files, FileResult{
				InputName: safeName,
				Kind:      kindFor(safeName),
				Error:     &msg,
			})
			continue
		}
		outPath := filepath.Join(outputDir, processed.OutputName)
		if err := os.WriteFile(outPath, processed.Data, 0o644); err != nil {
			msg := err.Error()
			diagnostics = append(diagnostics, msg)
			files = append(files, FileResult{
				InputName: safeName,
				Kind:      processed.Kind,
				Error:     &msg,
			})
			continue
		}
		preview := clipPreview(processed.Preview, &previewBudget)
		files = append(files, FileResult{
			InputName:  safeName,
			OutputName: &processed.OutputName,
			Kind:       processed.Kind,
			ByteCount:  len(processed.Data),
			Preview:    preview,
		})
	}

	ok := false
	for _, f := range files {
		if f.Error == nil {
			ok = true
			break
		}
	}
	return Result{
		OK:          ok,
		Operation:   req.Operation,
		Files:       files,
		Diagnostics: diagnostics,
	}
}

func errorResult(op Operation, message string) Result {
	return Result{
		OK:          false,
		Operation:   op,
		Files:       []FileResult{},
		Diagnostics: []string{message},
	}
}

type processedFile struct {
	OutputName string
	Kind       string
	Data       []byte
	Preview    string
}

func validatedFilename(name string) (string, error) {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" || strings.Contains(trimmed, "/") || strings.Contains(trimmed, "\\") ||
		strings.Contains(trimmed, "\x00") || trimmed == "." || trimmed == ".." {
		return "", fmt.Errorf("%s is not a safe file name.", name)
	}
	base := filepath.Base(trimmed)
	if base != trimmed {
		return "", fmt.Errorf("%s is not a safe file name.", name)
	}
	return base, nil
}

func kindFor(filename string) string {
	return strings.TrimPrefix(strings.ToLower(filepath.Ext(filename)), ".")
}

func process(path string, operation Operation, format OutputFormat) (processedFile, error) {
	filename := filepath.Base(path)
	fileKind := strings.TrimPrefix(strings.ToLower(filepath.Ext(filename)), ".")
	extracted, err := extractText(path, fileKind)
	if err != nil {
		return processedFile{}, err
	}

	if operation == OperationExtract {
		ext := "md"
		body := extracted
		if format == FormatTXT {
			ext = "txt"
		} else {
			body = fmt.Sprintf("# %s\n\n%s\n", filename, extracted)
		}
		return processedFile{
			OutputName: replaceExt(filename, ext),
			Kind:       fileKind,
			Data:       []byte(body),
			Preview:    extracted,
		}, nil
	}

	switch format {
	case FormatXLSX:
		if fileKind != "csv" && fileKind != "tsv" && fileKind != "txt" {
			return processedFile{}, fmt.Errorf("That conversion is not supported for %s files.", fileKind)
		}
		csv := extracted
		if fileKind == "tsv" {
			csv = strings.ReplaceAll(extracted, "\t", ",")
		}
		data, err := csvToXLSX(csv)
		if err != nil {
			return processedFile{}, err
		}
		return processedFile{
			OutputName: replaceExt(filename, "xlsx"),
			Kind:       fileKind,
			Data:       data,
			Preview:    extracted,
		}, nil
	case FormatCSV:
		if fileKind == "xlsx" {
			raw, err := os.ReadFile(path)
			if err != nil {
				return processedFile{}, err
			}
			csv, err := xlsxToCSV(raw)
			if err != nil {
				return processedFile{}, err
			}
			return processedFile{
				OutputName: replaceExt(filename, "csv"),
				Kind:       fileKind,
				Data:       []byte(csv),
				Preview:    csv,
			}, nil
		}
		if fileKind != "csv" && fileKind != "tsv" && fileKind != "txt" {
			return processedFile{}, fmt.Errorf("That conversion is not supported for %s files.", fileKind)
		}
		return processedFile{
			OutputName: replaceExt(filename, "csv"),
			Kind:       fileKind,
			Data:       []byte(extracted),
			Preview:    extracted,
		}, nil
	default:
		ext := "md"
		body := extracted
		if format == FormatTXT {
			ext = "txt"
		} else {
			body = fmt.Sprintf("# %s\n\n%s\n", filename, extracted)
		}
		return processedFile{
			OutputName: replaceExt(filename, ext),
			Kind:       fileKind,
			Data:       []byte(body),
			Preview:    extracted,
		}, nil
	}
}

func extractText(path, kind string) (string, error) {
	switch kind {
	case "pdf":
		return pdfToText(path)
	case "docx":
		raw, err := os.ReadFile(path)
		if err != nil {
			return "", err
		}
		return docxToText(raw)
	case "xlsx":
		raw, err := os.ReadFile(path)
		if err != nil {
			return "", err
		}
		return xlsxToCSV(raw)
	case "html", "htm":
		raw, err := os.ReadFile(path)
		if err != nil {
			return "", err
		}
		return htmlToText(string(raw)), nil
	default:
		raw, err := os.ReadFile(path)
		if err != nil {
			return "", err
		}
		return string(raw), nil
	}
}

func pdfToText(path string) (string, error) {
	if _, err := exec.LookPath("pdftotext"); err != nil {
		return "", fmt.Errorf("PDF text extraction is unavailable in this image.")
	}
	out, err := exec.Command("pdftotext", "-layout", path, "-").Output()
	if err != nil {
		return "", fmt.Errorf("PDF text extraction failed.")
	}
	return string(out), nil
}

func docxToText(data []byte) (string, error) {
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return "", err
	}
	for _, f := range reader.File {
		if f.Name != "word/document.xml" {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return "", err
		}
		defer rc.Close()
		return parseDocxXML(rc)
	}
	return "", fmt.Errorf("document.xml missing from docx")
}

func parseDocxXML(r io.Reader) (string, error) {
	decoder := xml.NewDecoder(r)
	var parts []string
	for {
		tok, err := decoder.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", err
		}
		if se, ok := tok.(xml.StartElement); ok && se.Name.Local == "t" {
			var text string
			if err := decoder.DecodeElement(&text, &se); err != nil {
				return "", err
			}
			if text != "" {
				parts = append(parts, text)
			}
		}
	}
	return strings.Join(parts, ""), nil
}

func xlsxToCSV(data []byte) (string, error) {
	book, err := excelize.OpenReader(bytes.NewReader(data))
	if err != nil {
		return "", err
	}
	sheets := book.GetSheetList()
	if len(sheets) == 0 {
		return "", nil
	}
	rows, err := book.GetRows(sheets[0])
	if err != nil {
		return "", err
	}
	var lines []string
	for _, row := range rows {
		lines = append(lines, strings.Join(row, ","))
	}
	return strings.Join(lines, "\n"), nil
}

func csvToXLSX(csv string) ([]byte, error) {
	book := excelize.NewFile()
	sheet := book.GetSheetName(0)
	lines := strings.Split(csv, "\n")
	for i, line := range lines {
		if line == "" {
			continue
		}
		cells := strings.Split(line, ",")
		for j, cell := range cells {
			cellName, _ := excelize.CoordinatesToCellName(j+1, i+1)
			_ = book.SetCellValue(sheet, cellName, cell)
		}
	}
	buf, err := book.WriteToBuffer()
	if err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func htmlToText(html string) string {
	var out strings.Builder
	inTag := false
	for _, r := range html {
		switch {
		case r == '<':
			inTag = true
		case r == '>':
			inTag = false
			out.WriteRune(' ')
		case !inTag:
			out.WriteRune(r)
		}
	}
	return strings.Join(strings.Fields(out.String()), " ")
}

func replaceExt(filename, ext string) string {
	base := strings.TrimSuffix(filename, filepath.Ext(filename))
	return base + "." + ext
}

func clipPreview(text string, remaining *int) *string {
	if *remaining <= 0 {
		return nil
	}
	limit := min(MaximumPreviewCharacters, *remaining)
	preview := text
	if len(preview) > limit {
		preview = preview[:limit] + "…"
	}
	*remaining -= len(preview)
	return &preview
}

func strPtr(s string) *string { return &s }
