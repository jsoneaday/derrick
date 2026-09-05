import Foundation

public enum ServiceLogLevel: String, Codable, Sendable, Hashable {
    case debug
    case info
    case warning
    case error
}

public struct ServiceLogEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let service: String
    public let level: String
    public let code: String?
    public let message: String
    public let detailJSON: String?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        service: String,
        level: ServiceLogLevel,
        code: String? = nil,
        message: String,
        detailJSON: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.service = service
        self.level = level.rawValue
        self.code = code
        self.message = message
        self.detailJSON = detailJSON
        self.createdAt = createdAt
    }
}
