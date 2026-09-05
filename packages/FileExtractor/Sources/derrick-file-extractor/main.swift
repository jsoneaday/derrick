import Foundation
import FileExtractor
import Structure

let input = FileHandle.standardInput.readDataToEndOfFile()
let decoder = JSONDecoder()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

let result: FileExtractorResult
if let request = try? decoder.decode(FileExtractorRequest.self, from: input) {
    do {
        result = try FileExtractorEngine.run(request: request)
    } catch {
        result = FileExtractorResult(
            ok: false,
            operation: request.operation,
            files: [],
            diagnostics: [error.localizedDescription]
        )
    }
} else {
    result = FileExtractorResult(
        ok: false,
        operation: .extract,
        files: [],
        diagnostics: ["File extractor input must be a valid JSON object."]
    )
}

if let output = try? encoder.encode(result) {
    FileHandle.standardOutput.write(output)
}

exit(result.ok ? 0 : 1)
