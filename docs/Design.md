# Design and Architecture of Derrick

## Core Design
Derrick does not provide many tools to agents. Instead Derrick provides a small set of tools that allow agents to write code to achieve whatever end goal desired. The code written runs inside of isolated docker containers.
- Derrick is intended to be used as an assistant that can also build tools through code.
- To avoid the need for engineering knowledge each tool creation path has a lot of model guidance and structure.

## Structure
This application is Protocol first. All major features must have a Protocol and internally use GoF Design Patterns. No exceptions. The Protocols can be found in the Structure spm.

## Core redesign vocabulary

The core redesign uses these terms consistently:

- **Module** — functionality running inside an existing process.
- **Service** — a standalone process with its own lifecycle and IPC boundary.
- **Actor** — anything attempting a capability, including an operator, UI, agent, plugin guest, module, or service.
- **SideEffect** — a host-mediated operation with an external consequence, such as network access, UI presentation, container execution, persistence mutation, or message delivery.
- **Command** — a typed request asking an endpoint to perform work.
- **Event** — a typed notification that something happened; it does not expect a response.
- **Model message** — model conversation data such as system, user, assistant, and tool messages.
- **Service message** — internal module/service communication.
- **Plugin SideEffect message** — a guest-to-host request such as `http.request` or `ui.present`.
- Concrete in-process implementations end in `Module`; standalone process implementations end in `Service`.
- Behavioral protocols use suffixes such as `Serving`, `Checking`, `Evaluating`, `Applying`, `Executing`, and `Storing`.

The core boundary is:

1. Validate the message contract.
2. Identify the Actor.
3. Check the Actor's capabilities.
4. Evaluate Guardrail Policy.
5. Apply the decision.
6. Execute the approved SideEffect.
7. Return a typed result and audit event.

The kernel authority owns lifecycle, capabilities, secrets, SideEffects, and Guardrail enforcement. Modules provide replaceable in-process functionality. Services provide standalone process boundaries. Plugins remain user-space programs and never authorize their own SideEffects.

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
