# Design and Architecture of Derrick

## Core Design
Derrick does not provide many tools to agents. Instead Derrick provides a small set of tools that allow agents to write code to achieve whatever end goal desired. The code written runs inside of isolated docker containers.
- Derrick is intended to be used as an assistant that can also build tools through code.
- To avoid the need for engineering knowledge each tool creation path has a lot of model guidance and structure.

## Structure
This application is Protocol first. All major features must have a Protocol and internally use GoF Design Patterns. No exceptions. The Protocols can be found in the Structure spm.

## Guardrail
Guardrail is Derrick's control plane in Structure (`Sources/Guardrail`).

Flow:

1. **Guardrail** — logical container
2. **Policy engine** — store-backed rules decide allow / deny / confirm HITL / require workflow / redact
3. **Enforcement** — those decisions gate workflow starts, MCP effector/tool calls, HITL confirmations, and content redaction (e.g. PII)

- Workflow starts: `StoreBackedWorkflowAdmissionPolicy` (`workflow_start` scope) → `WorkflowAdmissionPolicy.apply` in `WorkflowRuntimeEngine` (allow / deny / confirmHITL then resume or cancel).
- MCP tools/effectors: `StoreBackedToolGovernancePolicy` (`tool_invocation`) in the chat pipeline and again in MCPService before the tool runs.
- Content: same engine via `StoreBackedCompletionContentPolicy`.
- `WorkflowKind.pluginFactoryEdit` is denied by a Policy rule until editability ships.
- Plugins propose work; they do not authorize control outcomes.
