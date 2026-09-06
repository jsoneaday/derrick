import Foundation
import Plugin
import Structure

/// Supplies known-good Slack connector drafts for end-to-end messaging verification.
public actor E2EFactoryBuilder: PluginFactoryBuilder {
    private let scope: PluginFactoryCreateInput.ConnectorScope

    public init(scope: PluginFactoryCreateInput.ConnectorScope) {
        self.scope = scope
    }

    public func makeDraft(_ request: PluginFactoryBuilderRequest) async throws -> PluginFactoryDraft {
        fputs("[E2E] building reference Slack draft for \(scope.rawValue)\n", stderr)
        return ReferenceSlackConnectorDraft.make(scope: scope, userGoal: request.userGoal)
    }
}
