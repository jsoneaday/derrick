import Foundation

public enum FileExtractorEngineError: Error, LocalizedError, Sendable, Equatable {
    case tooManyFiles
    case emptyFileList
    case unsafeFilename(String)
    case missingInput(String)
    case missingPDFTool
    case pdfFailed(String)
    case unsupportedConversion(String)

    public var errorDescription: String? {
        switch self {
        case .tooManyFiles:
            return "You can process at most \(FileExtractorLimits.maximumFiles) files."
        case .emptyFileList:
            return "Choose at least one attached file."
        case .unsafeFilename(let name):
            return "\(name) is not a safe file name."
        case .missingInput(let name):
            return "\(name) was not found in /data/in."
        case .missingPDFTool:
            return "PDF text extraction is unavailable in this image."
        case .pdfFailed(let detail):
            return detail.isEmpty ? "PDF text extraction failed." : detail
        case .unsupportedConversion(let kind):
            return "That conversion is not supported for \(kind) files."
        }
    }
}

public enum FileExtractorEngine: Sendable {
    public static func run(
        request: FileExtractorRequest,
        inputDirectory: URL = URL(fileURLWithPath: FileExtractorLimits.inputDirectory),
        outputDirectory: URL = URL(fileURLWithPath: FileExtractorLimits.outputDirectory)
    ) throws -> FileExtractorResult {
        guard !request.files.isEmpty else {
            throw FileExtractorEngineError.emptyFileList
        }
        guard request.files.count <= FileExtractorLimits.maximumFiles else {
            throw FileExtractorEngineError.tooManyFiles
        }

        var files: [FileExtractorFileResult] = []
        var diagnostics: [String] = []
        var previewBudget = FileExtractorLimits.maximumTotalPreviewCharacters
        for name in request.files {
            let safeName = try validatedFilename(name)
            let inputURL = inputDirectory.appendingPathComponent(safeName)
            guard FileManager.default.isReadableFile(atPath: inputURL.path) else {
                files.append(
                    FileExtractorFileResult(
                        inputName: safeName,
                        kind: kind(for: safeName),
                        error: FileExtractorEngineError.missingInput(safeName).localizedDescription
                    )
                )
                continue
            }
            do {
                let processed = try process(
                    url: inputURL,
                    operation: request.operation,
                    format: request.outputFormat
                )
                try processed.data.write(
                    to: outputDirectory.appendingPathComponent(processed.outputName),
                    options: .atomic
                )
                files.append(
                    FileExtractorFileResult(
                        inputName: safeName,
                        outputName: processed.outputName,
                        kind: processed.kind,
                        byteCount: processed.data.count,
                        preview: clip(processed.preview, remaining: &previewBudget)
                    )
                )
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                diagnostics.append(message)
                files.append(
                    FileExtractorFileResult(
                        inputName: safeName,
                        kind: kind(for: safeName),
                        error: message
                    )
                )
            }
        }
        return FileExtractorResult(
            ok: files.contains { $0.error == nil },
            operation: request.operation,
            files: files,
            diagnostics: diagnostics
        )
    }

    public static func validatedFilename(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FileExtractorEngineError.unsafeFilename(name)
        }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("\0") {
            throw FileExtractorEngineError.unsafeFilename(name)
        }
        if trimmed == "." || trimmed == ".." {
            throw FileExtractorEngineError.unsafeFilename(name)
        }
        let base = URL(fileURLWithPath: trimmed).lastPathComponent
        guard base == trimmed else {
            throw FileExtractorEngineError.unsafeFilename(name)
        }
        return base
    }

    private struct ProcessedFile {
        var outputName: String
        var kind: String
        var data: Data
        var preview: String
    }

    private static func process(
        url: URL,
        operation: FileExtractorOperation,
        format: FileExtractorOutputFormat
    ) throws -> ProcessedFile {
        let filename = url.lastPathComponent
        let fileKind = kind(for: filename)
        let extracted = try extractText(url: url, kind: fileKind)
        if operation == .extract {
            let ext = format == .txt ? "txt" : "md"
            let body = format == .txt ? extracted : "# \(filename)\n\n\(extracted)\n"
            return ProcessedFile(
                outputName: replacingExtension(filename, with: ext),
                kind: fileKind,
                data: Data(body.utf8),
                preview: extracted
            )
        }
        switch format {
        case .xlsx:
            guard fileKind == "csv" || fileKind == "tsv" || fileKind == "txt" else {
                throw FileExtractorEngineError.unsupportedConversion(fileKind)
            }
            let csv = fileKind == "tsv" ? extracted.replacingOccurrences(of: "\t", with: ",") : extracted
            return ProcessedFile(
                outputName: replacingExtension(filename, with: "xlsx"),
                kind: fileKind,
                data: try Spreadsheet.csvToXLSX(csv),
                preview: extracted
            )
        case .csv:
            if fileKind == "xlsx" {
                let csv = try Spreadsheet.xlsxToCSV(try Data(contentsOf: url))
                return ProcessedFile(
                    outputName: replacingExtension(filename, with: "csv"),
                    kind: fileKind,
                    data: Data(csv.utf8),
                    preview: csv
                )
            }
            guard fileKind == "csv" || fileKind == "tsv" || fileKind == "txt" else {
                throw FileExtractorEngineError.unsupportedConversion(fileKind)
            }
            return ProcessedFile(
                outputName: replacingExtension(filename, with: "csv"),
                kind: fileKind,
                data: Data(extracted.utf8),
                preview: extracted
            )
        case .markdown, .txt:
            let ext = format == .txt ? "txt" : "md"
            let body = format == .txt ? extracted : "# \(filename)\n\n\(extracted)\n"
            return ProcessedFile(
                outputName: replacingExtension(filename, with: ext),
                kind: fileKind,
                data: Data(body.utf8),
                preview: extracted
            )
        }
    }

    private static func extractText(url: URL, kind: String) throws -> String {
        switch kind {
        case "pdf":
            return try TextExtract.pdfToText(url)
        case "docx":
            return try TextExtract.docxToText(try Data(contentsOf: url))
        case "xlsx":
            return try Spreadsheet.xlsxToCSV(try Data(contentsOf: url))
        case "html", "htm":
            return TextExtract.htmlToText(try String(contentsOf: url, encoding: .utf8))
        default:
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private static func kind(for filename: String) -> String {
        URL(fileURLWithPath: filename).pathExtension.lowercased()
    }

    private static func replacingExtension(_ filename: String, with ext: String) -> String {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return "\(base).\(ext)"
    }

    private static func clip(_ text: String, remaining: inout Int) -> String? {
        guard remaining > 0 else { return nil }
        let limit = min(FileExtractorLimits.maximumPreviewCharacters, remaining)
        let preview = text.count <= limit ? text : String(text.prefix(limit)) + "…"
        remaining -= preview.count
        return preview
    }
}
