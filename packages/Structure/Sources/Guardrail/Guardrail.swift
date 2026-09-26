import Foundation

/// Derrick's agent-control umbrella in Structure.
///
/// **Policy decides.** HITL and workflows are enforcement shapes for those decisions.
/// Plugins propose actions; they do not authorize control outcomes.
///
/// Folder layout:
/// - `Guardrail/Policy` — rules and interception contracts
/// - `Guardrail/HITL` — human confirmation wire types and presentation signals
/// - `Guardrail/Workflow` — workflow kinds, runtime DTOs, effector admission
public enum Guardrail: Sendable {}
