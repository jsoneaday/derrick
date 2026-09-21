import Foundation

public struct MessagingAgentRoute: Sendable, Hashable {
    public let pluginID: String
    public let threadID: String
    public let vendorThreadID: String
    public let parentVendorMessageID: String?
    public let inboundVendorMessageID: String
    public let profileHandle: String
    public let prompt: String

    public init(
        pluginID: String,
        threadID: String,
        vendorThreadID: String,
        parentVendorMessageID: String?,
        inboundVendorMessageID: String,
        profileHandle: String,
        prompt: String
    ) {
        self.pluginID = pluginID
        self.threadID = threadID
        self.vendorThreadID = vendorThreadID
        self.parentVendorMessageID = parentVendorMessageID
        self.inboundVendorMessageID = inboundVendorMessageID
        self.profileHandle = profileHandle
        self.prompt = prompt
    }
}

/// In-flight connector agent turn, shown in Derrick until a reply is posted.
public struct MessagingAgentWorkInFlight: Codable, Sendable, Hashable {
    public let pluginID: String
    public let threadID: String
    public let parentVendorMessageID: String
    public let profileHandle: String
    public let displayName: String

    public init(
        pluginID: String,
        threadID: String,
        parentVendorMessageID: String,
        profileHandle: String,
        displayName: String
    ) {
        self.pluginID = pluginID
        self.threadID = threadID
        self.parentVendorMessageID = parentVendorMessageID
        self.profileHandle = profileHandle
        self.displayName = displayName
    }

    public var statusLabel: String {
        "\(displayName) is working"
    }
}

/// Lightweight profile row for inbound help text and routing.
public struct AgentProfileCatalogEntry: Sendable, Hashable {
    public let handle: String
    public let displayName: String

    public init(handle: String, displayName: String) {
        self.handle = handle
        self.displayName = displayName
    }
}

public enum AgentProfileHelpFormatter: Sendable {
    public static func mentionOnlyPrompt(catalog: [AgentProfileCatalogEntry]) -> String {
        let lines = catalog.map { entry in
            "- $\(entry.handle) (\(entry.displayName))"
        }
        let profileList = lines.isEmpty
            ? "- $orchestrator (Orchestrator)\n- $developer (Developer)\n- $researcher (Researcher)\n- $general (General)"
            : lines.joined(separator: "\n")
        return """
        The user mentioned Derrick without a specific request. Briefly list the available agent profiles:
        \(profileList)

        Explain they can talk to a profile by putting $ and the short name at the start \
        (for example $orchestrator or $researcher). Mentioning a short name later in a sentence \
        does not switch profiles. Mention that this channel can have its own default profile in Derrick. Offer to help.
        """
    }
}

/// Parses connector message bodies for bot mentions and talk-to `$shortName` tokens.
public enum ConnectorMentionParser: Sendable {
    public static let botReplyPrefix = "[\(DerrickAppSupport.hostAppProductName)]"

    public static func botReplyPrefix(profileHandle: String) -> String {
        let handle = AgentProfileHandle.normalize(profileHandle)
            ?? profileHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if handle.isEmpty {
            return botReplyPrefix
        }
        return "[\(DerrickAppSupport.hostAppProductName):\(handle)]"
    }

    /// Reply under the inbound message, or stay in an existing thread.
    public static func agentReplyThreadParentVendorMessageID(
        inboundVendorMessageID: String,
        existingParentVendorMessageID: String?
    ) -> String {
        let existing = existingParentVendorMessageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !existing.isEmpty {
            return existing
        }
        return inboundVendorMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isAutomatedOutboundEcho(body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") else { return false }
        let name = DerrickAppSupport.hostAppProductName
        return trimmed.hasPrefix("[\(name)]") || trimmed.hasPrefix("[\(name):")
    }

    public static func resolvePrompt(
        body: String,
        continuationProfileHandle: String? = nil,
        channelDefaultProfileHandle: String? = nil,
        profileCatalog: [AgentProfileCatalogEntry] = []
    ) -> (profileHandle: String, prompt: String)? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = AgentProfileTokenParser.parse(message: trimmed)
        let continuation = AgentProfileHandle.normalize(continuationProfileHandle ?? "")

        let handle: String
        let promptSource: String
        if let parsedHandle = parsed.handle {
            handle = parsedHandle
            promptSource = parsed.body
        } else if let continuation {
            handle = continuation
            promptSource = trimmed
        } else {
            _ = channelDefaultProfileHandle
            return nil
        }

        let prompt = promptSource.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty {
            return (handle, AgentProfileHelpFormatter.mentionOnlyPrompt(catalog: profileCatalog))
        }
        return (handle, prompt)
    }

    /// Talk-to `$shortName`, or `[Derrick:handle]` on an automated reply.
    public static func profileHandle(inMessageBody body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let handle = AgentProfileTokenParser.parse(message: trimmed).handle {
            return handle
        }
        let name = DerrickAppSupport.hostAppProductName
        let prefix = "[\(name):"
        guard trimmed.hasPrefix(prefix),
              let close = trimmed[prefix.endIndex...].firstIndex(of: "]")
        else {
            return nil
        }
        return AgentProfileHandle.normalize(String(trimmed[prefix.endIndex..<close]))
    }

    /// Newest prior talk-to `$shortName` or `[Derrick:handle]` in a thread.
    public static func continuationProfileHandle(
        in messages: [MessagingMessageDTO],
        excludingVendorMessageID: String?
    ) -> String? {
        let excluded = excludingVendorMessageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for message in messages.reversed() {
            let vendorID = message.vendorMessageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !excluded.isEmpty, vendorID == excluded {
                continue
            }
            if let handle = profileHandle(inMessageBody: message.body) {
                return handle
            }
        }
        return nil
    }
}

public enum MessagingAgentSessionID {
    public static func make(pluginID: String, threadID: String, profileHandle: String) -> String {
        "messaging-\(pluginID)-\(threadID)-\(profileHandle)"
    }
}

public enum MessagingAgentOutboundFormatter {
    public static func formatReply(_ text: String, profileHandle: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(ConnectorMentionParser.botReplyPrefix(profileHandle: profileHandle)) \(trimmed)"
    }
}
