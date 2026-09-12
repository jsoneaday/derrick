package contract

import (
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"strings"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

//go:embed schemas/*.json
var schemaFS embed.FS

// ValidateHopEventJSON checks stdin against hop-event.schema.json.
func ValidateHopEventJSON(data []byte) error {
	return validate("hop-event.schema.json", data)
}

// ValidateEnvelopeListJSON checks stdout against envelope-list.schema.json.
func ValidateEnvelopeListJSON(data []byte) error {
	return validate("envelope-list.schema.json", data)
}

// ValidateWebCrawlerResultJSON checks crawler stdout against web-crawler-result.schema.json.
func ValidateWebCrawlerResultJSON(data []byte) error {
	return validate("web-crawler-result.schema.json", data)
}

// ValidateFileExtractorResultJSON checks extractor stdout against file-extractor-result.schema.json.
func ValidateFileExtractorResultJSON(data []byte) error {
	return validate("file-extractor-result.schema.json", data)
}

func validate(schemaName string, data []byte) error {
	compiler := jsonschema.NewCompiler()
	if err := loadSchemas(compiler); err != nil {
		return err
	}
	schema, err := compiler.Compile(schemaCompileURL(schemaName))
	if err != nil {
		return fmt.Errorf("compile schema %s: %w", schemaName, err)
	}
	var value any
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&value); err != nil {
		return fmt.Errorf("invalid json: %w", err)
	}
	if err := schema.Validate(value); err != nil {
		return fmt.Errorf("schema validation failed: %w", err)
	}
	return nil
}

const schemaBase = "https://derrick.local/schemas/"

func loadSchemas(compiler *jsonschema.Compiler) error {
	return fs.WalkDir(schemaFS, "schemas", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".json") {
			return nil
		}
		raw, err := schemaFS.ReadFile(path)
		if err != nil {
			return err
		}
		var doc any
		if err := json.Unmarshal(raw, &doc); err != nil {
			return fmt.Errorf("decode %s: %w", path, err)
		}
		name := strings.TrimPrefix(path, "schemas/")
		ids := schemaResourceIDs(name, doc)
		for _, id := range ids {
			if err := compiler.AddResource(id, doc); err != nil {
				return err
			}
		}
		return nil
	})
}

func schemaResourceIDs(filename string, doc any) []string {
	seen := map[string]bool{}
	add := func(id string) {
		if id == "" || seen[id] {
			return
		}
		seen[id] = true
	}
	add(schemaBase + filename)
	if m, ok := doc.(map[string]any); ok {
		if id, ok := m["$id"].(string); ok {
			add(id)
		}
	}
	ids := make([]string, 0, len(seen))
	for id := range seen {
		ids = append(ids, id)
	}
	return ids
}

func schemaCompileURL(name string) string {
	raw, err := schemaFS.ReadFile("schemas/" + name)
	if err != nil {
		return schemaBase + name
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err == nil {
		if id, ok := doc["$id"].(string); ok && id != "" {
			return id
		}
	}
	return schemaBase + name
}
