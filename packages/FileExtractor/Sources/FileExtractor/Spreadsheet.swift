import Foundation

enum Spreadsheet {
    static func csvToXLSX(_ csv: String) throws -> Data {
        let rows = CSV.parse(csv)
        var sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        """
        for (rowIndex, row) in rows.enumerated() {
            let r = rowIndex + 1
            sheet.append("<row r=\"\(r)\">")
            for (columnIndex, value) in row.enumerated() {
                let cell = cellName(column: columnIndex, row: r)
                let escaped = xmlEscape(value)
                sheet.append("<c r=\"\(cell)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escaped)</t></is></c>")
            }
            sheet.append("</row>")
        }
        sheet.append("</sheetData></worksheet>")

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """
        return try ZipArchive.write([
            "[Content_Types].xml": Data(contentTypes.utf8),
            "_rels/.rels": Data(rels.utf8),
            "xl/workbook.xml": Data(workbook.utf8),
            "xl/_rels/workbook.xml.rels": Data(workbookRels.utf8),
            "xl/worksheets/sheet1.xml": Data(sheet.utf8),
        ])
    }

    static func xlsxToCSV(_ data: Data) throws -> String {
        let entries = try ZipArchive.read(data)
        let shared = entries.first { $0.key.lowercased().hasSuffix("sharedstrings.xml") }.map {
            extractTaggedText($0.value, tag: "t")
        } ?? []
        guard let sheet = entries.first(where: { $0.key.lowercased().contains("worksheets/sheet") })?.value else {
            throw FileExtractorEngineError.unsupportedConversion("xlsx")
        }
        let xml = String(decoding: sheet, as: UTF8.self)
        var rows: [[String]] = []
        let rowParts = xml.components(separatedBy: "<row")
        for part in rowParts.dropFirst() {
            guard let end = part.range(of: "</row>") else { continue }
            let rowXML = String(part[..<end.lowerBound])
            var cells: [String] = []
            var rest = rowXML
            while let cellStart = rest.range(of: "<c ") ?? rest.range(of: "<c>") {
                rest = String(rest[cellStart.lowerBound...])
                guard let cellEnd = rest.range(of: "</c>") ?? rest.range(of: "/>") else { break }
                let cell = String(rest[..<cellEnd.upperBound])
                rest = String(rest[cellEnd.upperBound...])
                if cell.contains("t=\"inlineStr\"") || cell.contains("t='inlineStr'") {
                    cells.append(extractTaggedText(Data(cell.utf8), tag: "t").joined(separator: " "))
                } else if cell.contains("t=\"s\"") || cell.contains("t='s'"),
                          let index = extractTaggedText(Data(cell.utf8), tag: "v").first.flatMap(Int.init),
                          shared.indices.contains(index) {
                    cells.append(shared[index])
                } else {
                    cells.append(extractTaggedText(Data(cell.utf8), tag: "v").first ?? "")
                }
            }
            if !cells.isEmpty {
                rows.append(cells)
            }
        }
        return CSV.serialize(rows)
    }

    static func cellName(column: Int, row: Int) -> String {
        var index = column
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(65 + (index % 26))!) + letters
            index = index / 26 - 1
        } while index >= 0
        return "\(letters)\(row)"
    }

    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func extractTaggedText(_ data: Data, tag: String) -> [String] {
        let xml = String(decoding: data, as: UTF8.self)
        var values: [String] = []
        var rest = xml
        let open = "<\(tag)"
        while let start = rest.range(of: open) {
            rest = String(rest[start.upperBound...])
            guard let gt = rest.firstIndex(of: ">") else { break }
            if rest[rest.startIndex..<gt].hasSuffix("/") {
                rest = String(rest[rest.index(after: gt)...])
                continue
            }
            rest = String(rest[rest.index(after: gt)...])
            guard let end = rest.range(of: "</\(tag)>") else { break }
            values.append(
                String(rest[..<end.lowerBound])
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
            )
            rest = String(rest[end.upperBound...])
        }
        return values
    }
}

enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if inQuotes {
                if character == "\"" {
                    if let next = peek(iterator), next == "\"" {
                        _ = iterator.next()
                        field.append("\"")
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                row.append(field)
                field = ""
            } else if character == "\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { !$0.allSatisfy(\.isEmpty) }
    }

    static func serialize(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { field in
                if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) {
                    return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
                }
                return field
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    private static func peek(_ iterator: String.Iterator) -> Character? {
        var copy = iterator
        return copy.next()
    }
}
