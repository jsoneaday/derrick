# Design and Architecture of Derrick

## Core Design
Derrick does not provide many tools to agents. Instead Derrick provides a small set of tools that allow agents to write code to achieve whatever end goal desired. The code written runs inside of isolated docker containers.
- Derrick is intended to be used as an assistant that can also build tools through code.
- To avoid the need for engineering knowledge each tool creation path has a lot of model guidance and structure.

## Structure
This application is Protocol first. All major features must have a Protocol and internally use GoF Design Patterns. No exceptions. The Protocols can be found in the Structure spm.

## Guardrail
Guardrail is Derrick's control plane in Structure (`Sources/Guardrail`).

- **Policy decides** allow / deny / confirm HITL / require workflow / redact (`GuardrailDecision`).
- **HITL** and **workflows** are enforcement shapes for those decisions.
- **Plugins** propose capabilities; they do not authorize control outcomes.
- Workflow starts are admitted by `WorkflowAdmissionPolicy` inside `WorkflowRuntimeEngine` (UI proposes; Guardrail authorizes).
- Effector admission (for example sync `web.crawl`) uses the same decision vocabulary and is enforced in MCPService before the tool runs.
- `WorkflowKind.pluginFactoryEdit` is reserved for future plugin editability and is denied until enabled.
