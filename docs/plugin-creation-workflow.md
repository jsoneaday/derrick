# Plugin creation workflow

**Status:** Implemented (Plugins workspace, Sep 2026)  
**Related:** [workflow-orchestration-rfc.md](workflow-orchestration-rfc.md), [messaging-design.md](messaging-design.md), [AGENTS.md](../AGENTS.md)

This document describes the **guided plugin creation flow** in the Plugins workspace. Use it as the reference pattern when adding new multi-step, long-running workflows in Derrick.

---

## Why this pattern exists

Creating a connector plugin is slow and multi-step: crawl vendor docs, generate code, run Docker tests, pass an independent safety review, collect Keychain credentials, then open Messaging. That work cannot block a synchronous MCP `callTool` round-trip.

The plugin creation flow therefore combines:

1. **A host-owned wizard** — plain-language steps, scope presets, progress, credentials, and readable errors.
2. **A durable workflow** — `WorkflowKind.pluginFactoryCreate` runs in derrickd with pollable progress events.
3. **Long-running MCP effectors** — `web.crawl` and `plugin_factory_build` execute inside MCPService with explicit `ExecutionContextWire`.

Conversation agents are not the orchestrator for this path. The UI starts the workflow and polls until terminal state.

---

## Architecture overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Plugins workspace (SwiftUI)                                     │
│  PluginCreationController + PluginsWorkspaceView                 │
│  • Wizard phases (intro → type → vendor → describe → …)          │
│  • Progress checklist + status line                              │
│  • Credentials form → Keychain                                   │
└───────────────┬─────────────────────────────────────────────────┘
                │ WorkflowRuntimeClient.startWorkflow / poll
                ▼
┌─────────────────────────────────────────────────────────────────┐
│  WorkflowRuntimeEngine (derrickd)                                │
│  PluginFactoryCreateWorkflow                                     │
│    1. web.crawl (vendor docs)                                    │
│    2. plugin_factory_build (builder + test + reviewer)           │
└───────────────┬─────────────────────────────────────────────────┘
                │ executeTool (XPC → MCPService)
                ▼
┌─────────────────────────────────────────────────────────────────┐
│  MCPService                                                      │
│  • web.crawl (Docker)                                            │
│  • plugin_factory_build → ConfiguredPluginFactoryService         │
│      – Builder model → draft (source + test_input_json)          │
│      – Deterministic draft validation (host code)                │
│      – Direct test in Docker (hop replay)                        │
│      – Safety reviewer model (with thinking level)               │
│      – Package + verify                                          │
└─────────────────────────────────────────────────────────────────┘
```

**Separation of concerns**

| Layer | Responsibility |
|-------|----------------|
| UI wizard | User intent, scope, credentials, navigation, friendly errors |
| Workflow backend | Ordered steps, stage labels, terminal status, result JSON |
| MCP factory | Model calls, Docker execution, **deterministic gates**, review, release artifact |
| SQLite | `workflow_runs`, `workflow_events`, plugin factory releases |

---

## Wizard phases

The modal wizard in the Plugins workspace follows a fixed sequence:

| Phase | Purpose |
|-------|---------|
| **Intro** | Explain plugins; offer Create or Edit |
| **Choose type** | Connector / News reader / Custom (only connector is live today) |
| **Choose vendor** | Slack, Telegram, WhatsApp, Discord, Other |
| **Describe** | Scope preset + optional free-text requirements |
| **Creating** | Checklist + live status while workflow runs |
| **Collect credentials** | Keychain fields from manifest secrets (if any missing) |
| **Succeeded / Failed** | Open Messaging or retry with context |

Phases are owned by `PluginCreationController` (`ui/ui/Plugins/PluginCreationController.swift`). The view is `PluginsWorkspaceView`.

**Design rules used here (reuse for other workflows):**

- **Never dismiss** the modal during active work (`creating`).
- **Map failures back to a step** (`FailureStep`: type, vendor, description, creating) so Back lands on the right screen.
- **Sanitize errors for humans**; keep raw detail behind an expandable section.
- **Finish setup in the wizard** (credentials) instead of sending users to another surface to discover missing steps.

---

## Scope presets

Ambiguous goals cause review failures: the builder implements broad sync/receive behavior but the mock test only proves send.

The describe step requires a **scope preset** before optional detail text:

| Scope | Messaging ops | When to use |
|-------|---------------|-------------|
| **Send + receive** | `sync_threads`, `poll_inbox`, `send_message` | Channel list, pick one conversation, send and receive new messages |

Scope is stored on `PluginFactoryCreateInput.scope` and drives:

- **`connectorBuildGoal()`** — scope-specific requirements (no generic “must sync and send”).
- **`ConnectorReferenceBlueprint`** — vendor reference patterns and test fixture expectations injected into the factory goal.

The wizard always creates **Send + receive**. Send-only and full-sync remain in the enum for already-installed plugins and older workflow payloads.

Default wizard scope is **Send + receive**.

Types: `PluginFactoryCreateInput.ConnectorScope` in Structure.

---

## Workflow steps

`PluginFactoryCreateWorkflow` runs two MCP steps in order:

1. **`docs`** — `web.crawl` from the vendor’s documentation entry URL (skipped for custom vendors without a known URL).
2. **`factory`** — `plugin_factory_build` with a goal built from scope, user description, crawl summary, and reference blueprint.

On success, the workflow completes with `PluginFactoryCreateResult` JSON (`plugin_id`, `version`, `vendor`, `review_summary`).

On failure, the workflow sets `error_message` and a log event with a **stage** hint (`docs`, `factory`, `review`, …) so the wizard can return to the correct step.

Workflow kind: `WorkflowKind.pluginFactoryCreate`.

---

## Progress UX

While `creating`, the UI shows:

1. A **four-step checklist** — Read docs → Build and test → Safety review → Save credentials.
2. A **status line** mapped from workflow events (`WorkflowChatProgress.factoryProgressMessage`).

Events come from polling `WorkflowRuntimeClient.pollWorkflowUpdate`. Progress kinds include `progress` and factory log lines (`draft_started`, `direct_test`, `review decision=…`).

Technical log lines (reviewer findings, tool stderr) are **filtered out** of the status line via `WorkflowChatProgress.shouldSurfaceWorkflowMessage` so users see actionable progress, not raw model output.

---

## Builder, deterministic validation, direct test, and safety review

Inside `plugin_factory_build`, each builder attempt follows this pipeline:

```
Builder model (draft JSON)
    → Structural validation (host code, no LLM)
    → Direct test (Docker hop replay from test_input_json)
    → Post-test validation (host code, no LLM)
    → Safety reviewer model (independent — safety + semantics only)
    → Package + packaged hop test + post-test validation
    → Release saved to DB
```

### Deterministic draft validation (host code)

**Do not rely on the safety reviewer for requirements that code can decide.**

`PluginFactoryDraftValidator` runs before the reviewer and after the direct/packaged hop tests. Failures throw `PluginFactoryError.draftValidationFailed`, which is **builder-correctable**: `PluginFactorySession` feeds structured findings back to the builder model and retries (same as review rejection), without treating the whole workflow as a terminal user failure until the attempt budget is exhausted.

| Gate | When | Examples |
|------|------|----------|
| **Structure** | Before Docker | Valid manifest; Python stdin + forbidden imports; connector `messaging_ops` declared; `test_input_json` uses `hops` with fixtures; scope ops covered in test hops; unique fixture `request_id`s |
| **Direct test** | After hop replay | Exit 0; terminal `result.emit`; emitted `http.request` IDs match fixtures; scope-specific output shape (`sent_message`, `messages[]`, `threads[]`) |

Scope expectations are parsed from the user goal (`PluginFactoryValidationExpectations`) and compared to manifest `messaging_ops` and test hops.

Hop replay is implemented by `PluginFactoryHopTestRunner`: `test_input_json` is a JSON object with a `hops` array; each hop is fed to the guest program in order until a terminal envelope or the hop list ends.

**Retry contract:** validation failures do **not** abort the factory on the first miss. They increment the builder attempt counter (up to **three** total drafts) and return actionable bullet findings via `PluginFactorySession.builderFeedback`. Only after the budget is exhausted does the workflow fail for the user.

### Builder model

**Builder model** (`LLMModelSettings.pluginBuilderModel`) returns JSON including:

- `python_source`
- `test_input_json` — serialized JSON with a `hops` array and `http_results` fixtures
- `secrets`, `role`, `messaging_ops`, skill files, etc.

The host writes the canonical manifest (including default `messaging_ops` for connectors when omitted).

### Safety reviewer

**Safety reviewer** (`LLMModelSettings.pluginSafetyReviewerModel`) runs only after deterministic gates pass. It sees the user goal, manifest, `test_input_json`, source, and direct test output.

Use the reviewer for:

- Safety, privacy, supply-chain, and policy bypass checks
- Vendor semantics not fully captured by gates (e.g. subtle Slack `ok`/`error` handling, pagination completeness)
- Misleading or unrelated code

Do **not** use the reviewer as the primary gate for structural requirements already enforced by `PluginFactoryDraftValidator`.

Reviewer **thinking level** is configurable in Settings → Plugin safety reviewer (default **Medium**).

---

## Credentials step

After the workflow completes, the wizard loads secret descriptors from the saved manifest (`PluginCredentialCatalog` / `ConnectorCredentialService`).

If secrets are declared and not already in Keychain, the wizard shows **Collect credentials** before success. Values are saved with `ConnectorCredentialSaver` → `PluginSecretKeychain` — the same path Messaging uses later.

If there are no secrets, or all are already stored, the wizard skips straight to **Connector ready**.

---

## Failure handling

| Audience | Content |
|----------|---------|
| **User** | Short summary via `PluginFactoryCreateFailureMessage.presentation` — e.g. try again or a simpler goal |
| **Power user** | Expandable **Technical details** with raw reviewer or factory text |

Validation-heavy failures map `FailureStep` back to **description** so the user can change scope or wording and retry.

---

## Settings and model wiring

| Setting | Location | Used by |
|---------|----------|---------|
| Plugin builder model | Settings → Helper models / Plugin builder | `ConfiguredPluginFactoryBuilder` |
| Plugin safety reviewer model | Settings → Plugin safety reviewer | `ConfiguredPluginSafetyReviewer` |
| Reviewer thinking level | Settings → Plugin safety reviewer | Reviewer LLM call (`ModelThinkingOption`) |
| Chat API key | Provider credentials | `WorkflowStartRequest.helperAPIKey` |

The wizard session uses a dedicated chat session id (`plugin-wizard`) but does not require an open chat tab.

---

## Key files

| Area | Path |
|------|------|
| Wizard controller | `ui/ui/Plugins/PluginCreationController.swift` |
| Wizard UI | `ui/ui/Plugins/PluginsWorkspaceView.swift` |
| Workspace entry | `ui/ui/Views/ContentView.swift` (`.plugins`) |
| Workflow input / scope / goal | `packages/Structure/.../PluginFactoryCreateInput.swift` |
| Reference blueprint | `packages/Structure/.../ConnectorReferenceBlueprint.swift` |
| **Deterministic validation** | `packages/Structure/.../PluginFactoryDraftValidator.swift` |
| Validation expectations | `packages/Structure/.../PluginFactoryValidationExpectations.swift` |
| Hop test replay | `packages/Structure/.../PluginFactoryTestScript.swift` |
| Factory session + retry | `packages/Plugin/.../PluginFactoryImplementation.swift` |
| Failure copy | `packages/Structure/.../PluginFactoryCreateFailureMessage.swift` |
| Workflow runner | `packages/DerrickBackend/.../PluginFactoryCreateWorkflow.swift` |
| Workflow engine | `packages/DerrickBackend/.../WorkflowRuntimeEngine.swift` |
| Factory models | `ui/SharedAgentRuntime/Support/PluginFactoryModels.swift` |
| MCP registration | `ui/MCPService/MCPServiceToolHost.swift` |
| Progress strings | `packages/Structure/.../WorkflowChatProgress.swift` |
| Connector contract | `packages/Structure/.../ConnectorMessagingContract.swift` |

---

## Template for future workflows

When adding a new guided flow (e.g. edit plugin, news reader, custom job wizard), follow the same shape:

### 1. Host-owned wizard

- `ObservableObject` controller with explicit `Phase` enum.
- One workspace view with modal chrome (`modalPopup`).
- Collect structured input into a **Codable wire type** (like `PluginFactoryCreateInput`).
- Do not rely on chat parsing for ordering.

### 2. Durable workflow kind

- Add `WorkflowKind` case and handler in `WorkflowRuntimeEngine`.
- Implement `*Workflow.run(workflowID:request:…)` with:
  - `log` / `progress` events per stage
  - `fail(stage:message:)` with user-facing copy
  - `complete(resultJSON:)` on success
- Keep step order in **one** backend file, not in the UI.

### 3. Long effectors via MCP

- Start workflow from UI with `WorkflowRuntimeClient.startWorkflow`.
- Poll with `pollWorkflowUpdate`; map events to checklist + status line.
- Pass `helperAPIKey` and model wire JSON on `WorkflowStartRequest` when effectors need LLMs.

### 4. Scope and goal alignment

- Offer **presets** that narrow what automated tests must prove.
- Inject reference blueprints or examples into the goal passed to effectors.
- Align user-visible scope with deterministic validation expectations.

### 5. Deterministic gates before LLM review

**Required for any workflow that uses a builder model + independent reviewer.**

1. List every requirement that can be decided from artifacts alone (schema, test output, IDs, declared ops, etc.).
2. Implement a single `*DraftValidator` in Structure (or the owning package) with:
   - `validateStructure(...)` before expensive execution
   - `validateExecution(...)` after replay/tests
3. Throw a dedicated **builder-correctable** error (e.g. `draftValidationFailed(findings:)`).
4. Wire `*Session.builderFeedback(from:)` to turn findings into bullet instructions for the next builder call.
5. Cap retries with the same attempt budget as review rejection (plugin factory: **three** drafts).
6. Reserve the reviewer LLM for safety and judgment calls gates cannot make.

Do **not** fail the entire user workflow on the first validation miss — retry the builder with findings first.

### 6. Post-success setup in the wizard

- Any required secrets, permissions, or “open X to finish” steps happen **before** declaring success.
- Only then route to the destination workspace (here: Messaging).

### 7. Errors

- `userFacing` summary + optional `technicalDetail`.
- Map workflow stage → wizard step for Back navigation.
- Retry loops should pass **actionable** feedback into the next attempt (see `PluginFactorySession.builderFeedback`).

### 8. Progress contract

- Emit `progress` events with stable `stage` strings the UI checklist understands.
- Map noisy tool logs to short status strings; hide reviewer prose from the main status line.

### 9. Tests

- Wire types: encode/decode tests in `AppLayerServicesWireTests`.
- Goal/scope behavior: unit tests on input builders and `*ValidationExpectations`.
- Validator: unit tests for each gate (structure + execution).
- Session retry: builder receives feedback after `draftValidationFailed`.
- Workflow handler: `WorkflowRuntimeEngineTests` with stub `executeTool`.

---

## End-to-end user path

1. Sidebar → **Plugins** (intro modal: “Create or edit a plugin” — explains plugins and offers create or edit).
2. **Create plugin** → Connector → Vendor → Scope + description → **Create**.
3. Watch checklist: docs → build/review → credentials.
4. Enter bot token (or other secrets) → **Save and continue**.
5. **Open Messaging** to use the new connector.

---

## Related RFC status

[workflow-orchestration-rfc.md](workflow-orchestration-rfc.md) describes the general Process Manager pattern. Plugin creation is the **first shipped instance** of that pattern with a full UI wizard, scope presets, **deterministic draft validation**, credentials, and sanitized failure UX. Extend the RFC checklist with this doc when marking `/create-plugin` items complete.
