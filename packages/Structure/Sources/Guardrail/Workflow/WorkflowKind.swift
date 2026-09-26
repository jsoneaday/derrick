import Foundation

/// Sequenced procedures the harness can run. Policy may require one; plugins never authorize them.
///
/// `pluginFactoryEdit` is a reserved placeholder for future plugin editability.
public enum WorkflowKind: String, Codable, Sendable, Hashable, CaseIterable {
    case pluginFactoryCreate = "plugin_factory_create"
    case pluginFactoryEdit = "plugin_factory_edit"
    case connectorAuthDiscover = "connector_auth_discover"
    case jobStep = "job_step"
    case interactiveTool = "interactive_tool"
    case none
}
