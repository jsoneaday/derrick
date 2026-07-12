import AppKit
import SwiftUI

enum MarkdownBlock: Identifiable {
    case paragraph(String)
    case code(language: String?, code: String)

    var id: String {
        switch self {
        case .paragraph(let text):
            return "p-\(text.hashValue)"
        case .code(let language, let code):
            return "c-\(language ?? "")-\(code.hashValue)"
        }
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCodeBlock = false

        func flushParagraph() {
            let paragraph = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph))
            }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                    codeLines.removeAll(keepingCapacity: true)
                    codeLanguage = nil
                    inCodeBlock = false
                } else {
                    flushParagraph()
                    let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : String(language)
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
            } else if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraphLines.append(line)
            }
        }

        if inCodeBlock {
            blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
        } else {
            flushParagraph()
        }

        return blocks.isEmpty ? [.paragraph(text)] : blocks
    }
}

private struct CSVTable {
    let header: [String]
    let rows: [[String]]
}

private enum RichTextFormat {
    case csv(CSVTable)
    case markdown
    case plain
}

private enum RichTextClassifier {
    static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedNewlineCount = trimmed.components(separatedBy: "\\n").count - 1
        if escapedNewlineCount >= 3, !trimmed.contains("\n") {
            return trimmed.replacingOccurrences(of: "\\n", with: "\n")
        }
        return trimmed
    }

    static func classify(_ text: String) -> RichTextFormat {
        if let table = parseCSV(text) {
            return .csv(table)
        }
        if looksLikeMarkdown(text) {
            return .markdown
        }
        return .plain
    }

    private static func looksLikeMarkdown(_ text: String) -> Bool {
        let sample = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return sample.contains("```")
            || sample.contains("|")
            || sample.contains("**")
            || sample.contains("\n- ")
            || sample.contains("\n1. ")
            || sample.hasPrefix("#")
    }

    private static func parseCSV(_ text: String) -> CSVTable? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else { return nil }
        guard !lines[0].contains("|") else { return nil }

        let parsedRows = lines.map(splitCSVLine(_:))
        guard let header = parsedRows.first, header.count >= 2 else { return nil }
        let columnCount = header.count
        let body = Array(parsedRows.dropFirst())
        guard body.allSatisfy({ $0.count == columnCount }) else { return nil }

        return CSVTable(header: header, rows: body)
    }

    private static func splitCSVLine(_ line: String) -> [String] {
        var output: [String] = []
        var buffer = ""
        var inQuotes = false
        var index = line.startIndex

        while index < line.endIndex {
            let char = line[index]

            if char == "\"" {
                let next = line.index(after: index)
                if inQuotes, next < line.endIndex, line[next] == "\"" {
                    buffer.append("\"")
                    index = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
                index = next
                continue
            }

            if char == ",", !inQuotes {
                output.append(buffer.trimmingCharacters(in: .whitespaces))
                buffer = ""
            } else {
                buffer.append(char)
            }
            index = line.index(after: index)
        }

        output.append(buffer.trimmingCharacters(in: .whitespaces))
        return output
    }
}

struct MarkdownResponseView: View {
    let text: String
    var allowsCSVExport: Bool = true

    var body: some View {
        let normalized = RichTextClassifier.normalize(text)

        switch RichTextClassifier.classify(normalized) {
        case .csv(let table):
            csvTableView(table: table, source: normalized)
        case .markdown:
            markdownView(text: normalized)
        case .plain:
            Text(verbatim: normalized)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func markdownView(text: String) -> some View {
        let blocks = MarkdownBlock.parse(text)

        return VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                blockView(for: block)
            }
        }
    }

    @ViewBuilder
    private func blockView(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .lineSpacing(2)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal) {
                    Text(verbatim: code)
                        .font(.system(.body, design: .monospaced))
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(15)
            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func csvTableView(table: CSVTable, source: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(minWidth: 120, alignment: .leading)
                                .background(Color.black.opacity(0.04))
                        }
                    }

                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(minWidth: 120, alignment: .leading)
                            }
                        }
                        .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.black.opacity(0.02))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
            }

            if allowsCSVExport {
                HStack {
                    Spacer()
                    Button("Export CSV") {
                        exportCSV(source)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 15)
    }

    private func exportCSV(_ text: String) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "output.csv"
        panel.allowedFileTypes = ["csv"]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[MarkdownResponseView] failed to export csv: \(error)")
        }
    }
}
