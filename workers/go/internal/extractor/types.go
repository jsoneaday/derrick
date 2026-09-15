// Wire types mirror worker-product.schema.json (file_extractor_result) in Structure Contract.
package extractor

const (
	InputDirectory             = "/data/in"
	OutputDirectory            = "/data/out"
	MaximumFiles               = 5
	MaximumPreviewCharacters   = 8000
	MaximumTotalPreviewChars   = 32000
)

type Operation string

const (
	OperationExtract Operation = "extract"
	OperationConvert Operation = "convert"
)

type OutputFormat string

const (
	FormatMarkdown OutputFormat = "markdown"
	FormatTXT      OutputFormat = "txt"
	FormatCSV      OutputFormat = "csv"
	FormatXLSX     OutputFormat = "xlsx"
)

type Request struct {
	Operation    Operation    `json:"operation"`
	OutputFormat OutputFormat `json:"output_format"`
	Files        []string     `json:"files"`
}

type FileResult struct {
	InputName  string  `json:"input_name"`
	OutputName *string `json:"output_name,omitempty"`
	Kind       string  `json:"kind"`
	ByteCount  int     `json:"byte_count"`
	Preview    *string `json:"preview,omitempty"`
	Error      *string `json:"error,omitempty"`
}

type Result struct {
	OK          bool         `json:"ok"`
	Operation   Operation    `json:"operation"`
	Files       []FileResult `json:"files"`
	Diagnostics []string     `json:"diagnostics"`
}
