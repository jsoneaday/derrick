# RFC: Workflow orchestration and durable tool runs

**Status:** Draft — §9 decisions locked (2026-09-02)  
**Date:** 2026-09-02  
**Authors:** Derrick core  
**Related:** [adr-headless-backend.md](adr-headless-backend.md), [services-plan.md](services-plan.md), [AGENTS.md](../AGENTS.md)

## Summary

Replace **synchronous, timeout-bound XPC `callTool`** and **process-local turn flags** with two first-class primitives:

1. **`ExecutionContextWire`** — explicit, signed context on every cross-boundary call (no `TaskLocal` / in-memory registry as contract).
2. **`ToolRun` + `WorkflowRun`** — durable async execution with correlation IDs, progress events, and recovery.

`/create-plugin` becomes the first **Process Manager** workflow built on these primitives. Conversation agents **explain and react**; they do not enforce ordering via ad hoc guards.

---

## Problem

### 1. Long-running effectors over synchronous RPC

Today Agent (or UI) calls MCP with a blocking XPC round-trip and a client-side timeout (historically ~15s). Effectors such as `plugin_factory_build`, `web.crawl`, and `script_exec` routinely exceed that.

**Failure mode:** the caller gives up; the worker may still run; UI shows a stuck tool badge; state diverges across processes.

This is not a tuning problem. It is the wrong **interaction pattern** for work that outlives the transport.

### 2. Implicit context across process boundaries

Interactive turns set flags in `ExecutionContextRegistry` / `TaskLocal` (e.g. “plugin factory creation active”). MCP runs in **derrickd**, AgentService may run out-of-process, and policy reads different memory.

**Failure mode:** `web.crawl` blocked during `/create-plugin`, or crawl-before-build guards that only exist in one pipeline layer.

### 3. Workflow logic scattered in conversation code

`/create-plugin` ordering (crawl → build → review retry → credentials) is enforced by `ConversationPipelineToolInterception` and tracker objects. That duplicates what Jobs already do for background work and violates single-responsibility for the conversation agent.

---

## Goals

| Goal | Measure |
|------|---------|
| No orphan work | Every long effector has a durable `tool_run` row; caller detach does not imply cancel unless requested |
| Explicit boundaries | MCP policy reads `ExecutionContextWire` only — never process-local slots |
| Recoverable workflows | Daemon restart can resume or fail workflows with a clear terminal state |
| Live chat UX | UI streams progress events into the active turn (not only notification on completion) |
| Reuse existing infra | SQLite WAL, `ServiceMessageEnvelope`, HITL poll/notify, `job_steps` execution patterns |

## Non-goals (this RFC)

- Replacing Docker isolation or guest JSON contracts
- Public HTTP workflow API (WebhookService)
- Multi-machine distribution (single Mac, single SQLite)
- Removing conversation agents (they remain the user-facing voice)

---

## Design patterns (GoF map)

| Concern | Pattern | Derrick artifact |
|---------|---------|------------------|
| Start work without blocking transport | **Command** + correlation handle | `ToolRunCoordinator.start` → `run_id` |
| Progress to UI / Agent | **Observer** | `tool_run_events` + `AsyncStream` / reverse XPC |
| Multi-step `/create-plugin` | **State** + **Process Manager** | `WorkflowRun` state machine |
| Single entry for callers | **Facade** | `EffectorGateway` (Agent, Job, UI) |
| In-process vs XPC transport | **Bridge** | `InProcessServiceBridges` (optimization only) |
| Per-step implementation | **Strategy** | `WorkflowStepHandler` per `workflow_kind` |
| Cross-boundary context | **Value Object** | `ExecutionContextWire` (validated, versioned) |
| Signed inter-service messages | Existing envelope | `ServiceMessageEnvelope.correlationId` |

---

## Architecture overview

```
┌─────────────┐     start/subscribe      ┌──────────────────────┐
│ UI / Agent  │ ◄──────────────────────► │ ToolRunCoordinator   │
│  (Facade)   │   ExecutionContextWire   │  (daemon actor)      │
└──────┬──────┘                          └──────────┬───────────┘
       │                                              │
       │  turn chunks / progress events               │ dispatch
       ▼                                              ▼
┌─────────────┐                          ┌──────────────────────┐
│ Chat / debug│                          │ MCP tool host        │
│  projection │                          │ (Strategy executors) │
└─────────────┘                          └──────────────────────┘
       ▲                                              │
       │         append events                        │
       └──────────────────────────────────────────────┘
                          SQLite (WAL)
              tool_runs · tool_run_events
              workflow_runs · workflow_run_steps
```

**Rule:** synchronous `callTool` remains for **short** effectors only (memory search, catalog). Long effectors use **`startToolRun`**. Workflows use **`startWorkflow`**.

---

## 1. ExecutionContextWire

### Purpose

Replace cross-process inference (`ExecutionContextRegistry`, bool flags on `MCPToolCallRequest`) with an explicit, validated payload carried on every signed service message.

### Schema (v1)

Stored in `packages/Contract/Resources/schemas/execution-context-wire.schema.json` and mirrored in Swift (`ServiceContracts`).

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["schema_version", "session_id", "principal"],
  "properties": {
    "schema_version": { "const": 1 },
    "session_id": { "type": "string" },
    "turn_id": { "type": "string" },
    "agent_id": { "type": "string" },
    "principal": { "type": "string", "description": "ServicePrincipal wire form" },
    "workflow": {
      "type": "object",
      "properties": {
        "workflow_id": { "type": "string" },
        "kind": {
          "enum": [
            "plugin_factory_create",
            "plugin_factory_edit",
            "job_step",
            "interactive_tool",
            "none"
          ]
        },
        "step_id": { "type": "string" },
        "step_kind": { "type": "string" }
      }
    },
    "delivery": {
      "enum": ["live_chat", "notification", "silent"]
    },
    "capabilities": {
      "type": "array",
      "items": {
        "enum": ["sync_web_crawl", "host_review_retry"]
      }
    }
  }
}
```

### Policy examples

| Capability | MCP rule |
|--------------|----------|
| `sync_web_crawl` | Allow direct `web.crawl` (not only via `jobs_create`) |
| (absent) | `web.crawl` in live chat → blocked with structured outcome pointing at workflow or job path |

`plugin_factory_create` workflow kind implies `sync_web_crawl` for its crawl step — encoded in the workflow definition, not guessed from prompt text.

### Deprecation

- `TurnProcessContext.pluginFactoryCreationActive` → **debug-only** fallback during migration; removed in Phase 3.
- `ExecutionContextRegistry.setPluginFactoryCreationActive` → session-local cache for in-process fast path only; not authoritative.

---

## 2. ToolRun (durable async effector)

### State machine

```
accepted → running → { completed | failed | cancelled }
```

Optional substates via events only (not extra statuses): `building`, `reviewing`, `docker_test`, etc.

### Tables

#### `tool_runs`

| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PK | UUID; equals `requestID` / envelope `correlationId` |
| `tool_name` | TEXT | e.g. `plugin_factory_build` |
| `arguments_json` | TEXT | Frozen at start |
| `principal_json` | TEXT | `ServicePrincipal` |
| `context_json` | TEXT | `ExecutionContextWire` |
| `status` | TEXT | `accepted` \| `running` \| `completed` \| `failed` \| `cancelled` |
| `result_text` | TEXT | Terminal MCP-style outcome JSON |
| `is_error` | INTEGER | 0/1 |
| `error_message` | TEXT | Operator detail |
| `created_at` | TEXT | ISO8601 |
| `started_at` | TEXT | nullable |
| `finished_at` | TEXT | nullable |
| `lease_owner` | TEXT | daemon instance fingerprint |
| `lease_until` | TEXT | reclaim stuck `running` |

#### `tool_run_events`

Append-only progress log (Observer feed).

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | autoincrement |
| `run_id` | TEXT FK | → `tool_runs.id` |
| `seq` | INTEGER | monotonic per run |
| `kind` | TEXT | `progress` \| `log` \| `stage` |
| `stage` | TEXT | e.g. `builder`, `review`, `docker` |
| `message` | TEXT | human + debug |
| `detail_json` | TEXT | optional structured payload |
| `created_at` | TEXT | |

**Index:** `(run_id, seq)`.

### Coordinator API (daemon)

```swift
protocol ToolRunCoordinating: Sendable {
    /// Idempotent on `context` + frozen args hash when `idempotency_key` set.
    func start(_ request: ToolRunStartRequest) async throws -> ToolRunHandle

    func appendEvent(_ event: ToolRunEvent, runID: String) async throws

    func complete(
        runID: String,
        result: MCPToolCallResultDTO
    ) async throws

    /// Returns terminal state if already finished; otherwise streams events then terminal.
    func subscribe(runID: String) -> AsyncStream<ToolRunUpdate>

    func cancel(runID: String, reason: String) async throws
}
```

### Caller flow (Agent turn)

1. Build `ExecutionContextWire` for the turn.
2. `startToolRun` → `run_id` (XPC returns in &lt;100ms).
3. Yield UI chunk: `ToolCall started (run_id=…)` with `isProgress: true`.
4. `for await update in subscribe(run_id)` → forward progress to debug panel + chat.
5. On terminal event → feed slim result into agent follow-up (same as today’s `ToolFollowUpFormatter`).

**No client-side kill timer** on the subscribe loop. Terminal states come from coordinator or explicit `cancel`.

### MCP integration

`MCPServiceToolHost` long path:

1. Coordinator creates `tool_runs` row (`accepted`).
2. Task executes existing tool registration closure.
3. Logger closure → `appendEvent` (replaces stderr-only `[plugin_factory]` lines).
4. On return → `complete`.

Short path (unchanged): direct in-process call for tools under ~2s budget (configurable allowlist).

### Recovery

On daemon boot (mirror `JobService` reclaim):

- `running` rows with expired `lease_until` → `failed` with code `tool_run_lease_expired`, or `accepted` → re-dispatch if idempotent.
- UI/Agent subscribes or polls `tool_runs` by `turn_id` to heal stuck bubbles after relaunch.

---

## 3. WorkflowRun (Process Manager)

### Purpose

Model multi-step flows (`/create-plugin`, future `/edit-plugin`, composite crawls) as **one durable workflow** instead of conversation tool loops.

### `CreatePluginWorkflow` (v1)

| Step | Kind | Effector | Preconditions |
|------|------|----------|---------------|
| 1 | `crawl_vendor_docs` | `web.crawl` | `start_url` from agent or skill default policy |
| 2 | `factory_build` | `plugin_factory_build` | step 1 `completed` |
| 3 | `factory_review_retry` | `plugin_factory_build` | step 2 `blocked` @ review, retry not used |
| 4 | `collect_credentials` | UI HITL | step 2/3 `completed` with secrets |
| 5 | `invoke_plugin` | `plugin.invoke` | credentials satisfied (optional smoke) |

Transitions are **data-driven** (table or JSON definition), not hard-coded in `ConversationPipeline`.

### Tables

#### `workflow_runs`

| Column | Type |
|--------|------|
| `id` | TEXT PK |
| `kind` | TEXT | `plugin_factory_create` |
| `status` | TEXT | `running` \| `completed` \| `failed` \| `cancelled` |
| `context_json` | TEXT | `ExecutionContextWire` |
| `input_json` | TEXT | user prompt, plugin id, etc. |
| `current_step_id` | TEXT |
| `created_at`, `finished_at` | TEXT |

#### `workflow_run_steps`

| Column | Type |
|--------|------|
| `id` | TEXT PK |
| `workflow_id` | TEXT FK |
| `index` | INTEGER |
| `kind` | TEXT |
| `status` | TEXT | same as tool runs |
| `tool_run_id` | TEXT | nullable FK → `tool_runs` |
| `result_json` | TEXT |
| `created_at`, `started_at`, `finished_at` | TEXT |

### Coordinator

```swift
protocol WorkflowCoordinating: Sendable {
    func start(_ request: WorkflowStartRequest) async throws -> WorkflowHandle
    func subscribe(workflowID: String) -> AsyncStream<WorkflowUpdate>
    func cancel(workflowID: String, reason: String) async throws
}
```

`WorkflowEngine` (Strategy registry):

- `PluginFactoryCreateHandler` — defines steps, builds goals from prior step outputs.
- Future: `PluginFactoryEditHandler`, `ScheduledCrawlHandler`.

### Conversation agent role

- User: `/create-plugin slack connector`
- **Host** (UI on slash parse): `startWorkflow(plugin_factory_create, input)` — see §9.
- Agent: narrates progress from `subscribe(workflow_id)`; does **not** call `plugin_factory_build` or `workflows_start` for slash commands.
- Non-slash goals (“make me a Slack connector”) may still use a normal agent turn; v2 may add `workflows_start` as an agent tool with the same engine underneath.

---

## 4. Service surface (XPC / in-process)

All methods signed via `ServiceMessageEnvelope` with `correlationId` = run/workflow id.

### New (Daemon `DerrickDaemonServiceXPC`)

| Method | Request | Reply | Notes |
|--------|---------|-------|-------|
| `startToolRun` | `ToolRunStartRequest` | `ToolRunHandle` | Fast |
| `subscribeToolRun` | `runID` | stream of `ToolRunUpdate` | Duplex or repeated pull |
| `cancelToolRun` | `runID`, reason | `Ack` | |
| `startWorkflow` | `WorkflowStartRequest` | `WorkflowHandle` | Fast |
| `subscribeWorkflow` | `workflowID` | stream of `WorkflowUpdate` | |
| `cancelWorkflow` | `workflowID`, reason | `Ack` | |

### Deprecated (phased)

| Method | Fate |
|--------|------|
| `callTool` (long allowlist) | Thin wrapper → `startToolRun` + `subscribe` + await terminal for **JobService** compatibility; Agent uses native async API |
| `MCPToolCallRequest.pluginFactoryCreationActive` | Removed after `ExecutionContextWire` |

### Streaming transport

**Phase 1:** poll `tool_run_events` every 500ms–1s (same as HITL).  
**Phase 2:** reverse XPC sink on UI connection (`AgentServiceLogRelay` pattern) for push progress.  
**Phase 3:** multiplexed subscribe on single daemon connection.

---

## 5. Relationship to Jobs

Jobs remain the **schedule + principal + notify** container. Workflows are **interactive or one-shot multi-step** graphs.

| Use Jobs when | Use Workflow when |
|---------------|-------------------|
| `runAt` / recurrence | User is waiting in chat |
| Notification delivery | Step output feeds next step in same turn |
| Frozen one-shot tool | Policy-defined multi-step factory |

**Convergence (optional later):** `workflow_run_steps` and `job_steps` share the same `ToolRunCoordinator` executor. A job step becomes `runToolRun` instead of blocking `callTool`.

---

## 6. UI / debug panel

Progress projection rules:

- Chat: `isProgress` chunks from `WorkflowUpdate` / `ToolRunUpdate` (stage + short message).
- Debug: append `[tool_run id=… stage=builder] …` from `kind=log` events.
- Terminal: replace tool badge with formatted outcome (`PluginFactoryUserFacingFormatter`).

No silent multi-minute spinner without stage text.

---

## 7. Security and policy

- `ExecutionContextWire` is part of the **signed** payload; MCP rejects tampered capability expansion.
- `ToolRun` records `principal_json` at start; executor does not trust caller on complete.
- Cancel requires same principal or system.
- Workflow kinds are allowlisted; host slash commands use a fixed `workflow_kind` (see §7.1).

### 7.1 Policy integration

Derrick uses **stacked enforcement**, not one monolith. Workflow orchestration adds gates at **start**; it does not replace egress, script review, or factory safety review.

```
User prompt / LLM output
        │
        ▼
┌───────────────────────────────────────┐
│ Content policy (unchanged)            │  assistant_chunk / assistant_completion
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│ Tool / workflow governance            │  startWorkflow · startToolRun
│ scope: workflow_start, tool_run_start │  StoreBacked* + interceptAndRun
│         tool_invocation (agent tools) │
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│ Workflow engine (orchestration)       │  step preconditions — not policy_rules
└───────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────┐
│ Effector admission (MCP)              │  ExecutionContextWire.capabilities
│ Egress · script reviewer · factory    │  runs inside long ToolRun
└───────────────────────────────────────┘
```

**Rules:**

| Concern | Owner | Mechanism |
|---------|--------|-----------|
| May this workflow start? | Policy | `workflow_start` scope on `startWorkflow` |
| May this tool run start? | Policy | `tool_run_start` or existing `tool_invocation` |
| May this effector run in MCP? | Policy | `effector_admission` reads signed `ExecutionContextWire` (replaces hardcoded MCP gates) |
| Crawl before build | Workflow | `workflow_run_steps` preconditions — **not** `policy_rules` |
| Network per HTTP call | Egress | `BlacklistHTTPAccessGate` (unchanged; many calls per ToolRun) |
| Secrets in progress events | Content policy | Optional `tool_run_event` scope — redact before LLM (see §9) |

**GoF fit:** Chain of Responsibility (`PolicyEngine` rules), Interceptor (`interceptAndRun` at start only), Mediator (`WorkflowEngine` asks policy then advances — policy does not own the state machine).

**Not policy:** XPC timeouts, `ExecutionContextRegistry`, conversation pipeline guards (removed in Phase 3).

---

## 8. Migration plan

### Phase 0 — Document + schemas (this RFC)

- Review and lock v1 schemas.
- Add failing tests that document current bad behavior (sync timeout, missing context).

### Phase 1 — ExecutionContextWire

- [ ] JSON schema + Swift type + validation helper
- [ ] Thread through `MCPToolCallRequest` / envelope (wire field, not bool flag)
- [ ] MCP `effector_admission` policy reads wire capabilities
- [ ] Seed `workflow_start` rules for host-initiated kinds
- [ ] Remove `pluginFactoryCreationActive` bool after cutover

### Phase 2 — ToolRun coordinator

- [ ] Migrations `0031_tool_runs`, `0032_tool_run_events`
- [ ] `ToolRunCoordinator` actor in daemon
- [ ] `plugin_factory_build`, `web.crawl`, `script_exec` → start/subscribe path from Agent
- [ ] JobService: blocking wrapper for backward compat
- [ ] Reclaim job on daemon boot
- [ ] Progress events from factory logger

### Phase 3 — CreatePluginWorkflow

- [ ] Migrations `0033_workflow_runs`, `0034_workflow_run_steps`
- [ ] `PluginFactoryCreateHandler` state machine
- [ ] `/create-plugin` and `/edit-plugin` host entry → `startWorkflow` (slash parse in UI; no agent `workflows_start`)
- [ ] Remove `PluginFactoryTurnTracker` crawl guard + host review retry interception (logic moves to workflow)
- [ ] Keep `PluginFactoryReviewRetryPlanner` as workflow step policy

### Phase 4 — Transport polish

- [ ] Push progress via reverse XPC
- [ ] Unify subscribe API for UI and AgentService
- [ ] Metrics: p50/p95 run duration per tool

---

## 9. Decisions (locked)

1. **Cancel semantics:** User closes chat or cancels the turn → **cancel** workflow and Docker work (`cancelWorkflow` / `cancelToolRun`). No implicit kill via transport timeout. In-flight HITL rows resolve to `cancelled`.
2. **Idempotency:** **Dedupe** `startWorkflow` by `(session_id, kind, input_hash)` — return existing `workflow_id` instead of starting a duplicate run.
3. **Agent visibility:** Feed **all** `tool_run_events` into the agent follow-up path. Apply optional `tool_run_event` content-policy redaction before the model sees them (same machinery as `assistant_chunk`).
4. **Workflow start:** **Host-only** for `/create-plugin` and `/edit-plugin` slash commands. UI or daemon parses the slash command and calls `startWorkflow` directly. The conversation agent explains progress via `subscribe`; it does not choose to start the workflow. Deferred: `workflows_start` agent tool for non-slash natural-language requests.

---

## 10. Alternatives considered

| Alternative | Why not primary |
|-------------|-----------------|
| Longer XPC timeouts only | Caller still blocks; orphans on timeout; no progress |
| Bool flags on requests | Not signed semantics; easy to drift |
| Jobs-only for everything | Awkward live chat UX without workflow projection |
| Full in-process Agent+MCP | Hides boundary; conflicts with headless daemon ADR |
| Event choreography (no coordinator) | Cannot enforce crawl-before-build reliably |

---

## 11. Success criteria

- `/create-plugin slack connector` completes with visible stage progress and no XPC timeout.
- Kill UI mid-run → relaunch shows workflow/run status and terminal or resume policy.
- Zero policy decisions based on `ExecutionContextRegistry` across MCP boundary.
- `GuestContractAlignmentTests`-style tests for `ExecutionContextWire` and workflow transitions.

---

## Appendix A — Example sequences

### A.1 Interactive factory (target)

```
User → UI: /create-plugin slack connector
UI → Daemon: startWorkflow(plugin_factory_create, input)   // host-only; dedupe key
Daemon → UI: workflow_id (immediate)
UI → Agent: turn(prompt) // narrate; subscribe(workflow_id) streams events
Daemon: step crawl → startToolRun(web.crawl) → events… → complete
Daemon: step factory_build → startToolRun(plugin_factory_build) → events…
Daemon: step review_retry (if needed)
Daemon: step collect_credentials → HITL
Daemon: workflow completed
UI: credential modal + success copy
```

User closes chat → UI/daemon `cancelWorkflow(workflow_id)` → Docker teardown.

### A.2 Job-scheduled crawl (unchanged semantics)

```
Agent → jobs_create(web.crawl, …)
JobService → startToolRun (context.delivery = notification)
…
JobService → wakeAgent with slim result
```

---

## Appendix B — Module placement

| Piece | Package / target |
|-------|------------------|
| `ExecutionContextWire` schema | `packages/Contract` |
| Wire Swift types + validation | `packages/ServiceContracts` |
| `ToolRunCoordinator`, `WorkflowEngine` | `packages/DerrickBackend` or new `packages/WorkflowRuntime` |
| DB migrations | `packages/DBRepository` |
| XPC DTOs | `packages/ServiceContracts` |
| UI projection | `ui/SharedAgentRuntime` |
| Slash command entry | `ui/SharedAgentRuntime/Conversation/ConversationModel` |

---

*End of RFC.*
