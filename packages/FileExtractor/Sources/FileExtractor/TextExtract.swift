import Foundation
import Structure

enum TextExtract {
    static func htmlToText(_ html: String) -> String {
        var text = html
        text = replaceBlock(text, tag: "script")
        text = replaceBlock(text, tag: "style")
        var result = ""
        var skipping = false
        for character in text {
            if character == "<" {
                skipping = true
                if !result.hasSuffix(" ") && !result.hasSuffix("\n") {
                    result.append(" ")
                }
            } else if character == ">" {
                skipping = false
            } else if !skipping {
                result.append(character)
            }
        }
        return decodeEntities(result)
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func docxToText(_ data: Data) throws -> String {
        let entries = try ZipArchive.read(data)
        guard let document = entries.first(where: { $0.key.lowercased().hasSuffix("word/document.xml") })?.value else {
            throw FileExtractorEngineError.unsupportedConversion("docx")
        }
        return Spreadsheet.extractTaggedText(document, tag: "w:t").joined(separator: " ")
    }

    static func pdfToText(_ url: URL) throws -> String {
        let binaries = [
            "/usr/bin/pdftotext",
            "/opt/homebrew/bin/pdftotext",
            "/usr/local/bin/pdftotext",
        ]
        guard let binary = binaries.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw FileExtractorEngineError.missingPDFTool
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-layout", "-enc", "UTF-8", url.path, "-"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw FileExtractorEngineError.pdfFailed(error)
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceBlock(_ text: String, tag: String) -> String {
        var result = text
        while let start = result.range(of: "<\(tag)", options: .caseInsensitive),
              let end = result.range(of: "</\(tag)>", options: .caseInsensitive, range: start.lowerBound..<result.endIndex) {
            result.replaceSubrange(start.lowerBound..<end.upperBound, with: " ")
        }
        return result
    }

    private static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
