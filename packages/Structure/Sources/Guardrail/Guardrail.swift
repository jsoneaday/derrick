import Foundation

/// Derrick's agent-control umbrella in Structure.
///
/// Flow: **Policy evaluates rules → adapters apply `GuardrailDecision` → chokepoints only call those two.**
///
/// Naming (no exceptions):
/// - `Guardrail*` — control-plane types
/// - `*Evaluating` — rule interpreters (`Request` → `GuardrailDecision`)
/// - `*Applying` — decision adapters (decision → effect)
/// - `StoreBacked*Evaluating` — SQLite-backed interpreters in PolicyRuntime
public enum Guardrail: Sendable {}
