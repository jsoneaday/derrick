import SwiftUI

/// Messaging in-flight chip. Same control as chat.
public struct HostUIAgentWorkIndicator: View {
    public let status: String

    public init(status: String) {
        self.status = status
    }

    public var body: some View {
        HostUICompletionStatus(status: status)
    }
}
