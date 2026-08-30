# Background services plan

## Goals
- Agents and jobs run without the UI.
- UI is a human client only.
- Shared effectors (MCP); no duplicate tool stacks.
- Cheap path: frozen tool runs without a second LLM turn.
- Cognitive path: wake agent only when something must be decided.

## Processes

| Process | Bundle / Mach id | Owns |
| --- | --- | --- |
| **UI** | `derrick.ui` | Chat, settings, approvals; XPC client of Daemon; ensure Daemon up |
| **Daemon (`derrickd`)** | `derrick.ui.Daemon` | Headless LoginAgent: agent turns, jobs, MCP host, AppEventBus, **sole** UserNotifications poster |
| **WebhookService** | `derrick.ui.WebhookService` | Public HTTP → CreateJob / RunTool / WakeAgent (future) |
| **DockerHelper** | `derrick.ui.DockerRunnerHelper` | Constrained `docker` CLI runner for the shared Swift runtime (see [adr-swift-script-runtime.md](adr-swift-script-runtime.md)) |

See [adr-headless-backend.md](adr-headless-backend.md).

**Packaging (locked):** UI embeds **DockerRunnerHelper** XPC + **JobKeepAlive** LoginItem (`derrickd`). Agent/Job/MCP run **in-process** inside derrickd. UI talks only to the daemon Mach service (`<TEAM_ID>.derrick.shared.daemon`). Does not prevent sleep; overdue jobs start late with `status_detail`, interrupted `running` jobs fail with a clear code.

## Call rules

```
UI ──Mach XPC──► derrickd (Agent + Jobs + MCP modules)
derrickd Agent ──in-process──► MCP
derrickd Agent ──in-process──► Jobs (create / schedule)
derrickd Jobs ──at fire──► MCP (RunTool) / Agent (WakeAgent)
derrickd ──XPC──► DockerRunnerHelper
WebhookService (future) ──► derrickd
```

- Job / Webhook never run LLM turns outside the Agent module.
- Every MCP call carries a **principal** for policy.

### Job model
- **Job** = durable container: schedule (`runAt`), principal, source, status, steps.
- **Step kinds:** `runTool` | `runToolBatch` | `wakeAgent` | `runToolThenWake`.
- Notify-after-tool = `runToolThenWake` or graph `runTool` → `wakeAgent` (not a silent side-effect).
- Heartbeat / decision alerts = **schedules** that fire `wakeAgent` (or notify) steps, not a vague “event” step type.
- **ServiceEnsureUp** shared library: primary `ensureDaemon()` (Agent/MCP/Job ensure-up aliases to daemon).

### Job fire types (step kinds)
1. **runTool** — frozen tool+args; 0 LLM at fire.
2. **runToolBatch** — several tools in one step.
3. **wakeAgent** — prompt/envelope → agent turn (may call MCP).
4. **runToolThenWake** — tool then wake with result.

### AgentService
- May call **MCPService** immediately, or **JobService** to schedule.

## Ensure-up + health
1. `health()` → version + status.  
2. If connection fails → open XPC (launch-on-demand) → retry with backoff.  
3. Else error + point at `service_logs`.

## Auth (locked direction)
- **Peer:** code-sign requirement on XPC (extend `XPCPeerAuthentication`).
- **Message:** signed envelopes (`id`, `ts`, `from`, `to`, `type`, `payload`, `sig`) — HMAC-SHA256 v1.
  - **Debug** (`IS_DEBUG=true`): `MESSAGES_SECRET_KEY` from environment / `.env` (no Keychain).
  - **Release**: Keychain get-or-create random secret (`MessagesSecretKey`).
  - Live signed paths: UI→Agent `startTurn` / `cancelTurn` / peer install auth; Agent→MCP `callTool` / `searchTools`; reverse UI `approval` / `networkAccess`; peer fetch/install auth + acks; `ping`.
  - Unsigned: `health`, `bootstrap`, turn chunk stream, docker helper Application-XPC process runs.
  - Upgrade path to asymmetric later.
- Webhook: separate external auth; only WebhookService listens publicly.

## Logging + DB (locked)
- **One shared SQLite** in host app container / app support (`derrick.sqlite3`).
- Multi-process access: **WAL** + **`busy_timeout=5000`** + **`synchronous=NORMAL`** on every open (`DBRepository`).
- Table ownership by domain.
- **Log destination is exclusive (debug vs release):**
  - **Debug** (`IS_DEBUG=true`): all operator logs go to the **debug panel only**. Do **not** write `service_logs`.
  - **Non-debug**: all operator logs go to **`service_logs` only**. Do **not** write the debug panel.
- Domain: jobs tables (JobService), agents later (AgentService), existing memory/policy (today UI/Agent).

## Webhook liveness
- Self-health; bind fail → log + exit.
- **JobService** watchdog (when present); UI ensure-up on settings.

## P0 decisions (locked)

| # | Decision | Lock |
| --- | --- | --- |
| 1 | Packaging | **XPC services** embedded; **JobKeepAlive login LaunchAgent** holds JobService for user session |
| 2 | DB | **One shared SQLite**; multi-table ownership; WAL |
| 3 | Message auth | **HMAC** v1 (`MESSAGES_SECRET_KEY` in debug / Keychain in release) + XPC peer identity |
| 4 | Idle / sleep | Keep-alive while logged in; **idle sleep allowed** when no job runs; **PreventUserIdleSystemSleep** only while a job is executing |
| 5 | Policy, UI absent | **HITL queue** + UserNotifications (next); wait with timeout → fail closed |

## Phases

| Phase | Status | Deliverable |
| --- | --- | --- |
| **P0** | done | This ADR + locked decisions |
| **P1** | partial | ServiceContracts; AgentService XPC; bootstrap+DB; UI ensure-up; **turn stream via XPC**; **UI is client-only** (no local ConversationModel for chat) |
| **P2** | partial | `service_logs` migration + writer; AgentService writes on bootstrap/health |
| **P3** | done | MCPService XPC + UI ensure-up; peer handoff UI←MCP→Agent; effectors Agent→MCPService; `agents_*` local; script reviewer in MCPService; **egress preflight in Agent before callTool** (mid-flight remains backstop); **MCP docker via DockerRunnerHelper peer XPC** (UI prewarms + hands helper peer endpoint). |
| **P4** | done | Job + Agent + MCP folded into **derrickd** (in-process); UI → daemon Mach only; peer mesh + job-worker/watchdog removed. Jobs UI / webhook still open. |
| **P5** | pending | WebhookService |
| **P6** | pending | Persist agents, cancel trees, diagnostics UI |

## Out of scope
Society-of-mind free topology; replacing MCP; multi-agent on every task.
