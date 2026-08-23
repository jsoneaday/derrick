import Foundation

public enum FileExtractorOperation: String, Codable, Sendable, Hashable {
    case extract
    case convert
}

public enum FileExtractorOutputFormat: String, Codable, Sendable, Hashable {
    case markdown
    case txt
    case csv
    case xlsx
}

public struct FileExtractorRequest: Codable, Sendable, Hashable {
    public var operation: FileExtractorOperation
    public var outputFormat: FileExtractorOutputFormat
    public var files: [String]

    public init(
        operation: FileExtractorOperation = .extract,
        outputFormat: FileExtractorOutputFormat = .markdown,
        files: [String]
    ) {
        self.operation = operation
        self.outputFormat = outputFormat
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case operation
        case outputFormat = "output_format"
        case files
    }
}

public struct FileExtractorFileResult: Codable, Sendable, Hashable {
    public var inputName: String
    public var outputName: String?
    public var kind: String
    public var byteCount: Int
    public var preview: String?
    public var error: String?

    public init(
        inputName: String,
        outputName: String? = nil,
        kind: String,
        byteCount: Int = 0,
        preview: String? = nil,
        error: String? = nil
    ) {
        self.inputName = inputName
        self.outputName = outputName
        self.kind = kind
        self.byteCount = byteCount
        self.preview = preview
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case inputName = "input_name"
        case outputName = "output_name"
        case kind
        case byteCount = "byte_count"
        case preview
        case error
    }
}

public struct FileExtractorResult: Codable, Sendable, Hashable {
    public var ok: Bool
    public var operation: FileExtractorOperation
    public var files: [FileExtractorFileResult]
    public var diagnostics: [String]

    public init(
        ok: Bool,
        operation: FileExtractorOperation,
        files: [FileExtractorFileResult],
        diagnostics: [String] = []
    ) {
        self.ok = ok
        self.operation = operation
        self.files = files
        self.diagnostics = diagnostics
    }
}

public enum FileExtractorLimits {
    public static let maximumFiles = 5
    public static let maximumPreviewCharacters = 8_000
    public static let maximumTotalPreviewCharacters = 32_000
    public static let inputDirectory = "/data/in"
    public static let outputDirectory = "/data/out"
}
