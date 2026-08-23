import Foundation
import Testing
@testable import FileExtractor

struct FileExtractorTests {
    @Test func rejectsPathTraversalFilenames() throws {
        #expect(throws: FileExtractorEngineError.unsafeFilename("../secret.txt")) {
            _ = try FileExtractorEngine.validatedFilename("../secret.txt")
        }
        #expect(throws: FileExtractorEngineError.unsafeFilename("..")) {
            _ = try FileExtractorEngine.validatedFilename("..")
        }
        #expect(throws: FileExtractorEngineError.unsafeFilename("foo/bar.csv")) {
            _ = try FileExtractorEngine.validatedFilename("foo/bar.csv")
        }
        let name = try FileExtractorEngine.validatedFilename("notes.csv")
        #expect(name == "notes.csv")
    }

    @Test func convertsCSVToXLSXAndBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let input = root.appendingPathComponent("in", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "name,score\nAda,10\n".write(to: input.appendingPathComponent("notes.csv"), atomically: true, encoding: .utf8)
        let converted = try FileExtractorEngine.run(
            request: FileExtractorRequest(operation: .convert, outputFormat: .xlsx, files: ["notes.csv"]),
            inputDirectory: input,
            outputDirectory: output
        )
        #expect(converted.ok)
        #expect(converted.files.first?.outputName == "notes.xlsx")
        let xlsxURL = output.appendingPathComponent("notes.xlsx")
        #expect(FileManager.default.fileExists(atPath: xlsxURL.path))

        try FileManager.default.copyItem(at: xlsxURL, to: input.appendingPathComponent("notes.xlsx"))
        let extracted = try FileExtractorEngine.run(
            request: FileExtractorRequest(operation: .convert, outputFormat: .csv, files: ["notes.xlsx"]),
            inputDirectory: input,
            outputDirectory: output
        )
        #expect(extracted.ok)
        #expect(extracted.files.first?.preview?.contains("Ada") == true)
        #expect(extracted.files.first?.preview?.contains("10") == true)
    }

    @Test func extractsHTMLText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let input = root.appendingPathComponent("in", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "<html><body><h1>Hello</h1><script>alert(1)</script><p>World</p></body></html>"
            .write(to: input.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        let result = try FileExtractorEngine.run(
            request: FileExtractorRequest(files: ["page.html"]),
            inputDirectory: input,
            outputDirectory: output
        )
        #expect(result.ok)
        #expect(result.files.first?.preview?.contains("Hello") == true)
        #expect(result.files.first?.preview?.contains("World") == true)
        #expect(result.files.first?.preview?.contains("alert") == false)
    }

    @Test func extractsDOCXText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let input = root.appendingPathComponent("in", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t>Quarterly summary</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let zip = try ZipArchive.write(["word/document.xml": Data(document.utf8)])
        try zip.write(to: input.appendingPathComponent("memo.docx"))
        let result = try FileExtractorEngine.run(
            request: FileExtractorRequest(files: ["memo.docx"]),
            inputDirectory: input,
            outputDirectory: output
        )
        #expect(result.ok)
        #expect(result.files.first?.preview?.contains("Quarterly summary") == true)
    }
}
