import Foundation

public protocol NewsWorkerRunning: Sendable {
    func run(requestJSON: Data) async throws -> Data
}

public struct NewsReaderWorkerRequest: Codable, Sendable, Hashable {
    public var mode: NewsReaderMode
    public var sources: [NewsSource]
    public var topics: [String]
    public var maxCount: Int
    public var contextHint: String?

    public init(
        mode: NewsReaderMode,
        sources: [NewsSource],
        topics: [String],
        maxCount: Int,
        contextHint: String? = nil
    ) {
        self.mode = mode
        self.sources = sources
        self.topics = topics
        self.maxCount = maxCount
        self.contextHint = contextHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public func encodedJSON() throws -> Data {
        try JSONEncoder.service.encode(self)
    }
}

public struct NewsReaderWorkerArticle: Codable, Sendable, Hashable {
    public var title: String
    public var url: String
    public var detail: String?
    public var publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case title
        case url
        case detail
        case publishedAt = "published_at"
    }
}

public struct NewsReaderWorkerResult: Codable, Sendable, Hashable {
    public var ok: Bool
    public var mode: NewsReaderMode
    public var articles: [NewsReaderWorkerArticle]
    public var diagnostics: [String]
}

public struct NewsReaderRunResult: Codable, Sendable, Hashable {
    public var ok: Bool
    public var stdout: Data
    public var stderr: Data
    public var message: String

    public init(ok: Bool, stdout: Data = Data(), stderr: Data = Data(), message: String = "") {
        self.ok = ok
        self.stdout = stdout
        self.stderr = stderr
        self.message = message
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
