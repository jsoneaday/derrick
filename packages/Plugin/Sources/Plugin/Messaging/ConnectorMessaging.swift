import Foundation
import ServiceContracts

/// Vendor-agnostic connector messaging operations delivered through `plugin.invoke`.
public enum ConnectorMessagingOperation: String, Codable, Sendable, Hashable, CaseIterable {
    case syncThreads = "sync_threads"
    case pollInbox = "poll_inbox"
    case sendMessage = "send_message"
}

public struct ConnectorMessagingThread: Sendable, Hashable {
    public let vendorThreadID: String
    public let title: String

    public init(vendorThreadID: String, title: String) {
        self.vendorThreadID = vendorThreadID
        self.title = title
    }
}

public struct ConnectorMessagingMessage: Sendable, Hashable {
    public let vendorThreadID: String
    public let vendorMessageID: String
    public let direction: MessagingMessageDirection
    public let sender: String
    public let body: String
    public let createdAt: Date

    public init(
        vendorThreadID: String,
        vendorMessageID: String,
        direction: MessagingMessageDirection,
        sender: String,
        body: String,
        createdAt: Date
    ) {
        self.vendorThreadID = vendorThreadID
        self.vendorMessageID = vendorMessageID
        self.direction = direction
        self.sender = sender
        self.body = body
        self.createdAt = createdAt
    }
}

public struct ConnectorMessagingSentMessage: Sendable, Hashable {
    public let vendorMessageID: String
    public let createdAt: Date

    public init(vendorMessageID: String, createdAt: Date) {
        self.vendorMessageID = vendorMessageID
        self.createdAt = createdAt
    }
}

public struct ConnectorMessagingResult: Sendable, Hashable {
    public let threads: [ConnectorMessagingThread]
    public let messages: [ConnectorMessagingMessage]
    public let sentMessage: ConnectorMessagingSentMessage?
    public let terminalTitle: String?
    public let terminalSummary: String?

    public init(
        threads: [ConnectorMessagingThread] = [],
        messages: [ConnectorMessagingMessage] = [],
        sentMessage: ConnectorMessagingSentMessage? = nil,
        terminalTitle: String? = nil,
        terminalSummary: String? = nil
    ) {
        self.threads = threads
        self.messages = messages
        self.sentMessage = sentMessage
        self.terminalTitle = terminalTitle
        self.terminalSummary = terminalSummary
    }

    public var terminalDetail: String? {
        let parts = [terminalTitle, terminalSummary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ": ")
    }
}

public enum ConnectorMessagingHopBuilder: Sendable {
    public static func inputData(
        operation: ConnectorMessagingOperation,
        params: [String: PluginJSON] = [:]
    ) throws -> Data {
        var merged = params
        merged["messaging_op"] = .string(operation.rawValue)
        let kind: PluginEventKind = operation == .sendMessage ? .messageInRoom : .manual
        let event = PluginHopEvent(kind: kind, params: merged)
        return try JSONEncoder().encode(event)
    }
}

public enum ConnectorMessagingParser: Sendable {
    public static func parse(toolOutcomeText: String) throws -> ConnectorMessagingResult {
        guard let outcome = ToolExecutionOutcome.decode(from: toolOutcomeText) else {
            throw ConnectorMessagingError.invalidToolOutcome
        }
        guard outcome.status == .completed else {
            let detail = outcome.failureSummary ?? "plugin.invoke failed"
            throw ConnectorMessagingError.pluginFailed(detail)
        }
        guard let value = outcome.output?.value,
              let envelopeData = value.data(using: .utf8) else {
            throw ConnectorMessagingError.missingOutput
        }
        return try parse(envelopeJSON: envelopeData)
    }

    public static func parse(envelopeJSON: Data) throws -> ConnectorMessagingResult {
        let envelopes = try PluginEnvelopeList.decode(envelopeJSON)
        guard let terminal = envelopes.last(where: { $0.verb.classification == .terminal }) else {
            throw ConnectorMessagingError.missingTerminalEnvelope
        }
        return try parse(payload: terminal.payload)
    }

    public static func parse(payload: [String: PluginJSON]) throws -> ConnectorMessagingResult {
        let threads = try parseThreads(payload["threads"])
        let messages = try parseMessages(payload["messages"])
        let sent = try parseSentMessage(payload["sent_message"])
        return ConnectorMessagingResult(
            threads: threads,
            messages: messages,
            sentMessage: sent,
            terminalTitle: payload["title"]?.stringValue,
            terminalSummary: payload["summary"]?.stringValue
        )
    }

    public static func requireSentMessage(_ result: ConnectorMessagingResult) throws -> ConnectorMessagingSentMessage {
        if let sent = result.sentMessage {
            return sent
        }
        if let detail = result.terminalDetail {
            throw ConnectorMessagingError.pluginFailed(detail)
        }
        throw ConnectorMessagingError.invalidField("sent_message")
    }

    private static func parseThreads(_ value: PluginJSON?) throws -> [ConnectorMessagingThread] {
        guard let value else { return [] }
        guard case .array(let items) = value else {
            throw ConnectorMessagingError.invalidField("threads")
        }
        return try items.map { item in
            guard case .object(let object) = item,
                  let vendorThreadID = object["vendor_thread_id"]?.stringValue,
                  let title = object["title"]?.stringValue else {
                throw ConnectorMessagingError.invalidField("threads")
            }
            return ConnectorMessagingThread(vendorThreadID: vendorThreadID, title: title)
        }
    }

    private static func parseMessages(_ value: PluginJSON?) throws -> [ConnectorMessagingMessage] {
        guard let value else { return [] }
        guard case .array(let items) = value else {
            throw ConnectorMessagingError.invalidField("messages")
        }
        return try items.map { item in
            guard case .object(let object) = item,
                  let vendorThreadID = object["vendor_thread_id"]?.stringValue,
                  let vendorMessageID = object["vendor_message_id"]?.stringValue,
                  let directionRaw = object["direction"]?.stringValue,
                  let direction = MessagingMessageDirection(rawValue: directionRaw),
                  let sender = object["sender"]?.stringValue,
                  let body = object["body"]?.stringValue else {
                throw ConnectorMessagingError.invalidField("messages")
            }
            let createdAt = parseDate(object["created_at"]) ?? .now
            return ConnectorMessagingMessage(
                vendorThreadID: vendorThreadID,
                vendorMessageID: vendorMessageID,
                direction: direction,
                sender: sender,
                body: body,
                createdAt: createdAt
            )
        }
    }

    private static func parseSentMessage(_ value: PluginJSON?) throws -> ConnectorMessagingSentMessage? {
        guard let value else { return nil }
        if case .null = value { return nil }
        guard case .object(let object) = value else {
            throw ConnectorMessagingError.invalidField("sent_message")
        }
        let vendorMessageID = object["vendor_message_id"].flatMap(stringValue(from:))
        guard let vendorMessageID, !vendorMessageID.isEmpty else {
            throw ConnectorMessagingError.invalidField("sent_message")
        }
        return ConnectorMessagingSentMessage(
            vendorMessageID: vendorMessageID,
            createdAt: parseDate(object["created_at"]) ?? .now
        )
    }

    private static func stringValue(from value: PluginJSON?) -> String? {
        guard let value else { return nil }
        if let string = value.stringValue {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if case .number(let number) = value {
            return String(number)
        }
        return nil
    }

    private static func parseDate(_ value: PluginJSON?) -> Date? {
        guard let value else { return nil }
        if let string = value.stringValue {
            if let numeric = Double(string) {
                return Date(timeIntervalSince1970: numeric)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }
        if case .number(let value) = value {
            return Date(timeIntervalSince1970: value)
        }
        return nil
    }
}

public enum ConnectorMessagingError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput
    case invalidToolOutcome
    case pluginFailed(String)
    case missingOutput
    case missingTerminalEnvelope
    case invalidField(String)
    case invokeUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Connector messaging input is invalid."
        case .invalidToolOutcome:
            return "Connector plugin returned an unreadable tool outcome."
        case .pluginFailed(let detail):
            return detail
        case .missingOutput:
            return "Connector plugin returned no output."
        case .missingTerminalEnvelope:
            return "Connector plugin returned no terminal result envelope."
        case .invalidField(let name):
            return "Connector plugin result is missing or mis-shaped field \(name)."
        case .invokeUnavailable:
            return "plugin.invoke is not available in this process."
        }
    }
}
