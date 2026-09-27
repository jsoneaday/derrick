# Derrick Core Redesign Plan

## Scope

This plan covers item 1 of issue 47: the core redesign. The Chat, Plugin, and
Configuration screen redesign is item 2 and is deferred until this plan is
complete.

The design is microkernel-inspired:

- The kernel owns authority, lifecycle, boundaries, secrets, and SideEffects.
- Modules provide replaceable in-process functionality.
- Services provide standalone process boundaries.
- Plugins are user-space programs.

## Naming

Concrete names must identify their execution boundary:

- `AgentOrchestrationModule` — in-process implementation.
- `JobSchedulingModule` — in-process implementation.
- `SessionMemoryModule` — in-process implementation.
- `NetworkSideEffectModule` — in-process implementation.
- `UISideEffectModule` — in-process implementation.
- `MCPClientModule` and `MCPServerModule` — in-process implementations.
- `AgentService`, `JobService`, `MCPService`, and `DockerRunnerService` —
  standalone processes.

Behavioral protocols retain behavioral suffixes:

- `*Serving`
- `*Checking`
- `*Evaluating`
- `*Applying`
- `*Executing`
- `*Storing`

Names must not become `ModuleModule` or `ServiceService`.

## Protocol rule

No existing protocol may be changed and no new protocol may be added without
first presenting the exact protocol and types to the operator for approval.

No module or feature may be built without an approved protocol contract and
typed request, response, and event types.

Existing `Structure` protocols are the starting point. The first implementation
step after Phase 0 is a protocol decision gate.

## Phase 0 — Baseline and architecture audit

Status: complete.

Completed:

- Created `refactor/core-redesign` from merged `main`.
- Audited package dependencies and direct implementation imports.
- Audited AgentRuntime orchestration.
- Audited the current scheduler and daemon bootstrap.
- Locked terminology in `docs/Design.md`.
- Confirmed no protocol was changed or added.

### Scheduler finding

`JobServiceScheduler` already exists. It polls schedules and jobs, claims work,
recovers interrupted jobs, and invokes job execution.

`DaemonModuleBootstrap` currently starts it in-process inside `derrickd` and
marks the jobs module ready. This plan does **not** move a scheduler from a
standalone service to a module. The current runtime is already in-process; the
directory name does not establish a process boundary.

The first implementation will formalize the existing behavior as a
`JobSchedulingModule`. A future standalone implementation may be named
`JobSchedulingService`, but that process extraction is not part of the first
refactor.

## Phase 1 — Protocol decision gate

Present exact contracts and types for approval before implementation.

### Agent orchestration

Use these existing protocols as the base:

- `AgentMailboxing`
- `AgentDirectorying`
- `TurnRunning`

Propose a composite `AgentOrchestrationServing` contract only after reviewing
those existing shapes.

### Job scheduling

Propose `JobSchedulingServing` for start, stop, health, claiming, recovery, and
cancellation. The first implementation wraps `JobServiceScheduler`; it does
not create a second scheduler.

### Process supervision

Propose `ProcessSupervising` for launch, stop, cancel, health, restart,
timeouts, resource limits, and orphan cleanup.

### Actors and capabilities

Propose typed contracts for:

- `ActorID`
- `ActorKind`
- `CapabilityID`
- `CapabilitySet`
- `CapabilityRequest`
- Capability decisions

`agentID` remains the identity of an agent and is not silently reinterpreted as
the universal Actor identity.

### SideEffect Broker

Propose:

- `HostSideEffectExecuting`
- `NetworkSideEffectExecuting`
- `UISideEffectExecuting`
- Host secret resolution and attachment contracts

## Phase 2 — Separate message families

Use separate typed families:

1. **Service messages** — commands, requests, responses, lifecycle messages,
   events, actor context, correlation, cancellation, and errors between host
   modules and services.
2. **Model messages** — system, user, assistant, and tool conversation data,
   model requests, streaming chunks, usage, and provider failures.
3. **Plugin SideEffect messages** — `http.request`, `ui.present`, tool requests,
   result envelopes, and artifact requests.
4. **AppEvents** — host notifications, not RPC or authorization.

`sourceService` and `destinationService` identify host endpoints. A model
provider is addressed through a model client/provider adapter, not as a
Derrick service.

## Phase 3 — Kernel runtime and process supervision

Create the composition boundary for modules, services, SideEffect providers,
Guardrail, capabilities, process supervision, and transport.

The supervisor manages standalone services, Docker guests, plugin runtimes, and
helper processes. An in-process module is supervised as part of its containing
process.

Define startup, shutdown, readiness, restart, backoff, timeout, cancellation,
resource limits, orphan cleanup, and audit behavior.

Every launch follows:

```text
Message validation
→ Actor identification
→ Capability check
→ Guardrail evaluation
→ Approved launch plan
→ Process supervisor
```

## Phase 4 — AgentOrchestrationModule consolidation

Consolidate these existing pieces behind one approved module contract:

- `AgentMailboxing`
- `AgentDirectorying`
- `TurnRunning`
- `InMemoryAgentDirectory`
- `InMemoryMailbox`
- `HierarchicalOrchestrator`
- `SessionOrchestrator`
- Agent turn routing

The `AgentOrchestrationModule` owns registration, parent/child relationships,
mailboxes, turn scheduling, concurrency, depth limits, cancellation, status,
and result routing.

It works with `SessionMemoryModule`, but they remain separate:

- Orchestration owns live coordination.
- Session memory owns retrieval, ingestion, summaries, compaction, and archive.
- Inbox messages are not automatically memory records.

The first implementation is in-process. A future `AgentOrchestrationService`
can implement the same contract without changing callers.

### AgentConfiguration and instance identity

`AgentProfile` terminology is replaced by `AgentConfiguration`:

- `AgentConfiguration` — durable configuration/template.
- `AgentConfigurationCatalog` — persistence and lookup contract.
- `AgentConfigurationTurnContext` — resolved configuration for a turn.
- `configurationHandle` — human-facing configuration identifier.

An LLM model remains a separate concept. An `AgentConfiguration` references
model settings, but it is not the model and it is not the runtime agent.

The runtime identity model is:

- `AgentInstance` — the live domain agent.
- `AgentRuntime` — in-memory execution machinery for that instance.
- `AgentRecord` — durable control-plane record for the instance while live and
  after termination.
- `AgentTurnRecord` — historical record for an individual turn.

Configurations are immutable and versioned. A running instance stores an
`AgentConfigurationReference` containing:

- `configurationID`
- `configurationVersion`
- Optional snapshot hash for verification

The reference is stored on `AgentRecord`, carried through trusted execution
context, recorded on each `AgentTurnRecord`, and retained as memory
provenance. `sessionID + agentID` remains the memory ownership scope; the
configuration reference does not replace the runtime agent identity.

Editing a configuration creates a new version. Existing instances remain
pinned to their original version unless explicitly refreshed or restarted.

## Phase 5 — JobSchedulingModule

Formalize `JobServiceScheduler` behind `JobSchedulingServing`.

Inject approved ports for:

- Clock
- Job and schedule storage
- Workflow starting
- Process supervision
- Event publication
- Capability checking
- Guardrail

Keep schedule creation and schedule execution as separate authorization
decisions. Revalidate Actor, job, workflow, capabilities, and Policy when a
schedule fires.

`JobKeepAlive` and daemon bootstrap must not create competing scheduling loops.
There must be one authoritative `JobSchedulingModule` per runtime.

## Phase 6 — Actor capabilities, Guardrail, and SideEffect Broker

Capabilities define the maximum authority of an Actor:

- `network.request`
- `ui.present`
- `workflow.start`
- `docker.run`
- `memory.read`
- `memory.write`
- `message.send`

The order is:

```text
Capability check
→ Guardrail evaluation
→ Guardrail application
→ SideEffect execution
```

Guardrail may restrict or pause a capability but cannot expand the Actor's
capability set.

The SideEffect Broker centralizes validation, Actor identification, capability
checks, Guardrail, HITL, secret scope, provider selection, audit, and result
normalization.

## Phase 7 — Network, UI, and secrets

`NetworkSideEffectModule` validates `http.request`, checks capabilities and
Guardrail, resolves only plugin-declared credentials, attaches generic
Bearer/Basic credentials, applies SSRF rules, and returns sanitized results.

`UISideEffectModule` validates `ui.present`, checks capabilities and Guardrail,
persists approved HostUI trees, notifies the UI, and returns typed interaction
results.

Go guests never receive raw secrets or construct native SwiftUI/AppKit.

Web crawling and file conversion receive narrow, explicit capability profiles.
They do not create broad network or UI permissions for arbitrary Go guests.

Model provider credentials, service credentials, database credentials, and
plugin HTTP credentials remain separate host-only secret scopes.

## Phase 8 — Platform modules

Refactor platform functionality behind focused approved contracts:

- Database storage contracts by bounded context.
- `SessionMemoryModule` over `MemoryStore`.
- Model client over `AgentModel`, `AgentProvider`, and `HTTPTransport`.
- `MCPClientModule` as transport only.
- `MCPServerModule` as registration, dispatch, validation, and encoding only.

MCP does not duplicate capability checks or Guardrail evaluation. The
SideEffect Broker is the authority path.

## Phase 9 — Plugin runtime and system plugins

User and system plugins use the same manifest, Go guest ABI, SideEffect
envelopes, result protocol, and runtime.

System/user differences are visibility, creation rights, edit rights,
capability grants, distribution, and upgrade policy. System plugins remain
user-space programs and do not bypass the SideEffect Broker or Guardrail.

Plugin source, skills, binaries, and packages remain runtime-managed artifacts,
not repository source.

## Phase 10 — Migration and verification

Migrate in this order:

1. Approve contracts.
2. Establish message families.
3. Establish lifecycle and supervision.
4. Consolidate `AgentOrchestrationModule`.
5. Formalize `JobSchedulingModule`.
6. Add Actor capability checks.
7. Add the SideEffect Broker.
8. Add network and UI modules.
9. Isolate secrets.
10. Narrow database and memory dependencies.
11. Simplify model and MCP transport roles.
12. Consolidate plugin runtime boundaries.
13. Migrate callers.
14. Delete bypasses and obsolete types.

Verify:

- Agent mailboxes and session memory remain separate.
- Only one scheduler claims due work.
- Scheduler recovery works after interruption.
- Actors cannot exceed capabilities.
- Guardrail cannot expand capabilities.
- Containers cannot make direct network calls or construct native UI.
- Plugin secrets never enter guest input, environment, arguments, or logs.
- Model API keys remain host-only.
- MCP cannot bypass the SideEffect Broker.
- Services, modules, guests, and system plugins use approved contracts.

## Phase 11 — Final documentation

Update `docs/Design.md`, this plan, package boundary documentation, and
`AGENTS.md`.

`AGENTS.md` must include:

> Never change an existing protocol or add a new one without first asking the
> operator. Never build a module or feature that does not have a protocol
> contract and types. If a new protocol is needed, ask the operator first.
