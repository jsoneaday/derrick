import Foundation

/// Canonical Derrick connector protocol decoded from `connector-contract.json`.
public struct ConnectorProtocolDocument: Codable, Sendable, Hashable {
    public var version: Int
    public var ops: [String: ConnectorOpSpec]
    public var scopes: [String: ConnectorScopeSpec]
    public var rules: ConnectorProtocolRules

    public func scope(id: String) throws -> ConnectorScopeSpec {
        guard let scope = scopes[id] else {
            throw ConnectorContractError.unknownScope(id)
        }
        return scope
    }
}

public struct ConnectorOpSpec: Codable, Sendable, Hashable {
    public var kind: String
    public var emit: String
    public var params: [String]
    public var mayCall: [String]
    public var mustNotCall: [String]
    public var whenNoParent: ConnectorOpCallSet?
    public var whenParent: ConnectorOpCallSet?
    public var success: ConnectorOpSuccess
    public var failure: ConnectorOpFailure?

    enum CodingKeys: String, CodingKey {
        case kind, emit, params, success, failure
        case mayCall = "may_call"
        case mustNotCall = "must_not_call"
        case whenNoParent = "when_no_parent"
        case whenParent = "when_parent"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        emit = try container.decode(String.self, forKey: .emit)
        params = try container.decodeIfPresent([String].self, forKey: .params) ?? []
        mayCall = try container.decodeIfPresent([String].self, forKey: .mayCall) ?? []
        mustNotCall = try container.decodeIfPresent([String].self, forKey: .mustNotCall) ?? []
        whenNoParent = try container.decodeIfPresent(ConnectorOpCallSet.self, forKey: .whenNoParent)
        whenParent = try container.decodeIfPresent(ConnectorOpCallSet.self, forKey: .whenParent)
        success = try container.decodeIfPresent(ConnectorOpSuccess.self, forKey: .success)
            ?? ConnectorOpSuccess()
        failure = try container.decodeIfPresent(ConnectorOpFailure.self, forKey: .failure)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(emit, forKey: .emit)
        try container.encode(params, forKey: .params)
        try container.encode(mayCall, forKey: .mayCall)
        try container.encode(mustNotCall, forKey: .mustNotCall)
        try container.encodeIfPresent(whenNoParent, forKey: .whenNoParent)
        try container.encodeIfPresent(whenParent, forKey: .whenParent)
        try container.encode(success, forKey: .success)
        try container.encodeIfPresent(failure, forKey: .failure)
    }
}

public struct ConnectorOpCallSet: Codable, Sendable, Hashable {
    public var mayCall: [String]

    enum CodingKeys: String, CodingKey {
        case mayCall = "may_call"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mayCall = try container.decodeIfPresent([String].self, forKey: .mayCall) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mayCall, forKey: .mayCall)
    }
}

public struct ConnectorOpSuccess: Codable, Sendable, Hashable {
    public var emptyCollectionOK: Bool
    public var emptyArrayOKIfVendorOK: Bool
    public var requiresSentMessage: Bool

    enum CodingKeys: String, CodingKey {
        case emptyCollectionOK = "empty_collection_ok"
        case emptyArrayOKIfVendorOK = "empty_array_ok_if_vendor_ok"
        case requiresSentMessage = "requires_sent_message"
    }

    public init(
        emptyCollectionOK: Bool = false,
        emptyArrayOKIfVendorOK: Bool = false,
        requiresSentMessage: Bool = false
    ) {
        self.emptyCollectionOK = emptyCollectionOK
        self.emptyArrayOKIfVendorOK = emptyArrayOKIfVendorOK
        self.requiresSentMessage = requiresSentMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emptyCollectionOK = try container.decodeIfPresent(Bool.self, forKey: .emptyCollectionOK) ?? false
        emptyArrayOKIfVendorOK = try container.decodeIfPresent(Bool.self, forKey: .emptyArrayOKIfVendorOK) ?? false
        requiresSentMessage = try container.decodeIfPresent(Bool.self, forKey: .requiresSentMessage) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(emptyCollectionOK, forKey: .emptyCollectionOK)
        try container.encode(emptyArrayOKIfVendorOK, forKey: .emptyArrayOKIfVendorOK)
        try container.encode(requiresSentMessage, forKey: .requiresSentMessage)
    }
}

public struct ConnectorOpFailure: Codable, Sendable, Hashable {
    public var vendorOKFalseEmptyIsNotSuccess: Bool
    public var codes: [String]

    enum CodingKeys: String, CodingKey {
        case vendorOKFalseEmptyIsNotSuccess = "vendor_ok_false_empty_is_not_success"
        case codes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vendorOKFalseEmptyIsNotSuccess =
            try container.decodeIfPresent(Bool.self, forKey: .vendorOKFalseEmptyIsNotSuccess) ?? false
        codes = try container.decodeIfPresent([String].self, forKey: .codes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vendorOKFalseEmptyIsNotSuccess, forKey: .vendorOKFalseEmptyIsNotSuccess)
        try container.encode(codes, forKey: .codes)
    }
}

public struct ConnectorScopeSpec: Codable, Sendable, Hashable {
    public var ops: [String]
    public var includeReplyPoll: Bool
    public var testPagination: String
    public var pollMustNotCall: [String]

    enum CodingKeys: String, CodingKey {
        case ops
        case includeReplyPoll = "include_reply_poll"
        case testPagination = "test_pagination"
        case pollMustNotCall = "poll_must_not_call"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ops = try container.decode([String].self, forKey: .ops)
        includeReplyPoll = try container.decode(Bool.self, forKey: .includeReplyPoll)
        testPagination = try container.decode(String.self, forKey: .testPagination)
        pollMustNotCall = try container.decodeIfPresent([String].self, forKey: .pollMustNotCall) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ops, forKey: .ops)
        try container.encode(includeReplyPoll, forKey: .includeReplyPoll)
        try container.encode(testPagination, forKey: .testPagination)
        try container.encode(pollMustNotCall, forKey: .pollMustNotCall)
    }
}

public struct ConnectorProtocolRules: Codable, Sendable, Hashable {
    public var syncThreadsListsTabsOnly: Bool
    public var pollLoadsOneConversation: Bool
    public var paginateWithinOp: Bool
    public var liveHTTPResultsAccumulate: Bool
    public var directTestPollRequiresNonEmptyMessages: Bool
    public var directTestThreadsRequiresNonEmpty: Bool
    public var runtimeEmptyMessagesOKIfVendorOK: Bool

    enum CodingKeys: String, CodingKey {
        case syncThreadsListsTabsOnly = "sync_threads_lists_tabs_only"
        case pollLoadsOneConversation = "poll_loads_one_conversation"
        case paginateWithinOp = "paginate_within_op"
        case liveHTTPResultsAccumulate = "live_http_results_accumulate"
        case directTestPollRequiresNonEmptyMessages = "direct_test_poll_requires_non_empty_messages"
        case directTestThreadsRequiresNonEmpty = "direct_test_threads_requires_non_empty"
        case runtimeEmptyMessagesOKIfVendorOK = "runtime_empty_messages_ok_if_vendor_ok"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        syncThreadsListsTabsOnly = try container.decode(Bool.self, forKey: .syncThreadsListsTabsOnly)
        pollLoadsOneConversation = try container.decode(Bool.self, forKey: .pollLoadsOneConversation)
        paginateWithinOp = try container.decode(Bool.self, forKey: .paginateWithinOp)
        liveHTTPResultsAccumulate = try container.decode(Bool.self, forKey: .liveHTTPResultsAccumulate)
        directTestPollRequiresNonEmptyMessages =
            try container.decodeIfPresent(Bool.self, forKey: .directTestPollRequiresNonEmptyMessages) ?? true
        directTestThreadsRequiresNonEmpty =
            try container.decodeIfPresent(Bool.self, forKey: .directTestThreadsRequiresNonEmpty) ?? true
        runtimeEmptyMessagesOKIfVendorOK =
            try container.decodeIfPresent(Bool.self, forKey: .runtimeEmptyMessagesOKIfVendorOK) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(syncThreadsListsTabsOnly, forKey: .syncThreadsListsTabsOnly)
        try container.encode(pollLoadsOneConversation, forKey: .pollLoadsOneConversation)
        try container.encode(paginateWithinOp, forKey: .paginateWithinOp)
        try container.encode(liveHTTPResultsAccumulate, forKey: .liveHTTPResultsAccumulate)
        try container.encode(directTestPollRequiresNonEmptyMessages, forKey: .directTestPollRequiresNonEmptyMessages)
        try container.encode(directTestThreadsRequiresNonEmpty, forKey: .directTestThreadsRequiresNonEmpty)
        try container.encode(runtimeEmptyMessagesOKIfVendorOK, forKey: .runtimeEmptyMessagesOKIfVendorOK)
    }
}

public struct ConnectorVendorProfile: Codable, Sendable, Hashable {
    public var vendor: String
    public var vendorOKField: String
    public var membershipFlag: String?
    public var paginationCursor: String?
    public var calls: [String: ConnectorVendorCall]

    enum CodingKeys: String, CodingKey {
        case vendor, calls
        case vendorOKField = "vendor_ok_field"
        case membershipFlag = "membership_flag"
        case paginationCursor = "pagination_cursor"
    }
}

public struct ConnectorVendorCall: Codable, Sendable, Hashable {
    public var method: String
    public var url: String
}

public enum ConnectorContractError: Error, Equatable, LocalizedError, Sendable {
    case missingResource(String)
    case invalidJSON(String)
    case unknownScope(String)
    case integrityFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "Missing bundled connector contract resource \(name)."
        case .invalidJSON(let name):
            return "Connector contract resource \(name) is not valid JSON."
        case .unknownScope(let id):
            return "Unknown connector scope \(id)."
        case .integrityFailed(let detail):
            return "Connector contract JSON failed schema checks: \(detail)"
        }
    }
}
