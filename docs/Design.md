# Design and Architecture of Derrick

## Core Design
Derrick does not provide many tools to agents. Instead Derrick provides a small set of tools that allow agents to write code to achieve whatever end goal desired. The code written runs inside of isolated docker containers.
- Derrick is intended to be used as an assistant that can also build tools through code.
- To avoid the need for engineering knowledge each tool creation path has a lot of model guidance and structure.

## Structure
This application is Protocol first. All major features must have a Protocol and internally use GoF Design Patterns. No exceptions. The Protocols can be found in the Structure spm.

## Guardrail
Guardrail is Derrick's control plane in Structure (`Sources/Guardrail`).

Flow: **Policy evaluates rules → adapters apply `GuardrailDecision` → chokepoints only call those two.**

Naming (no exceptions):

- `Guardrail*` — control-plane types
- `*Evaluating` — rule interpreters (`Request` → `GuardrailDecision`)
- `*Applying` — decision adapters (decision → effect)
- `StoreBacked*Evaluating` — SQLite-backed interpreters in `packages/PolicyRuntime`

- Workflow starts: `StoreBackedWorkflowStartEvaluating` (`workflow_start`) → `WorkflowStartGuardrailApplying` in `WorkflowRuntimeEngine`.
- MCP tools/effectors: `StoreBackedToolInvocationEvaluating` (`tool_invocation`) → `ToolInvocationGuardrailApplying` in the chat pipeline and MCPService.
- Content: `StoreBackedAssistantContentEvaluating` → `AssistantContentGuardrailApplying`.
- HITL: `GuardrailHITLPresenting` (shared); adapters take a presenter, chokepoints do not switch on decisions.
- `WorkflowKind.pluginFactoryEdit` is denied by a Policy rule until editability ships.
- Plugins propose work; they do not authorize control outcomes.
