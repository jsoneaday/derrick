import Foundation
import Security

/// Code-signing peer checks for NSXPC connections between Derrick components.
///
/// This is **platform peer identity** (who may talk on the XPC bus), not application-level
/// signed messaging between sub-apps/webhooks (that remains a separate backlog item).
public enum XPCPeerAuthentication: Sendable {
    /// Main app bundle id (XPC client of the helper).
    public static let mainAppIdentifier = "derrick.ui"
    /// Embedded helper XPC service id (XPC server).
    public static let dockerHelperIdentifier = "derrick.ui.DockerRunnerHelper"
    /// Agent runtime XPC service.
    public static let agentServiceIdentifier = "derrick.ui.AgentService"
    /// Job scheduler XPC service.
    public static let jobServiceIdentifier = "derrick.ui.JobService"
    /// MCP tools XPC service.
    public static let mcpServiceIdentifier = "derrick.ui.MCPService"
    /// Webhook ingress XPC service.
    public static let webhookServiceIdentifier = "derrick.ui.WebhookService"
    /// Login LaunchAgent that holds JobService open for the user session.
    public static let jobKeepAliveIdentifier = "derrick.ui.JobKeepAlive"
    /// Headless session backend (LoginAgent).
    public static let daemonIdentifier = "derrick.ui.Daemon"

    public enum PeerRole: Sendable {
        /// Helper accepting connections — peer must be the main app.
        case helperAcceptingApp
        /// Anonymous helper peer accepting MCPService connections.
        case helperAcceptingMCP
        /// App connecting to helper — peer must be the helper service.
        case appConnectingToHelper
    }

    public enum Error: Swift.Error, Equatable, LocalizedError, Sendable {
        case missingSigningInformation
        case invalidRequirement(String)
        case applyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingSigningInformation:
                return "Could not read this process’s code signing information."
            case .invalidRequirement(let detail):
                return "Invalid XPC code signing requirement: \(detail)"
            case .applyFailed(let detail):
                return "Failed to apply XPC code signing requirement: \(detail)"
            }
        }
    }

    /// Builds a requirement string for the expected peer identifiers, pinned to this process’s Team ID when available.
    public static func requirementString(
        allowedPeerIdentifiers: [String],
        teamIdentifier: String? = currentTeamIdentifier()
    ) -> String {
        let identifiers = allowedPeerIdentifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        precondition(!identifiers.isEmpty, "allowedPeerIdentifiers must not be empty")

        let identifierClause: String
        if identifiers.count == 1 {
            identifierClause = "identifier \"\(identifiers[0])\""
        } else {
            identifierClause = "(" + identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ") + ")"
        }

        if let teamIdentifier, !teamIdentifier.isEmpty {
            // Same Apple Development/Distribution team as this process.
            return "\(identifierClause) and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }

        // Ad-hoc / missing team: still require the expected identifier (weaker, but better than open).
        return identifierClause
    }

    public static func requirementString(for role: PeerRole) -> String {
        switch role {
        case .helperAcceptingApp:
            return requirementString(allowedPeerIdentifiers: [mainAppIdentifier])
        case .helperAcceptingMCP:
            return requirementString(allowedPeerIdentifiers: [mcpServiceIdentifier])
        case .appConnectingToHelper:
            return requirementString(allowedPeerIdentifiers: [dockerHelperIdentifier])
        }
    }

    /// Development-only escape hatch for ad-hoc Debug builds whose anonymous
    /// XPC endpoints cannot satisfy a code-signing requirement.
    public static func isDebugMode(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["IS_DEBUG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
    }

    /// Applies the requirement to `connection`. Call **before** `resume()`.
    public static func apply(_ role: PeerRole, to connection: NSXPCConnection) throws {
        try apply(requirement: requirementString(for: role), to: connection)
    }

    public static func apply(requirement: String, to connection: NSXPCConnection) throws {
        do {
            try connection.setCodeSigningRequirement(requirement)
        } catch {
            throw Error.applyFailed(error.localizedDescription)
        }
    }

    /// Team ID of the current process, if signed with a team.
    public static func currentTeamIdentifier() -> String? {
        signingInfoString(key: kSecCodeInfoTeamIdentifier)
    }

    /// Code signing identifier of the current process (usually the bundle id).
    public static func currentSigningIdentifier() -> String? {
        signingInfoString(key: kSecCodeInfoIdentifier)
    }

    private static func signingInfoString(key: CFString) -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else {
            return nil
        }
        return dict[key as String] as? String
    }
}
