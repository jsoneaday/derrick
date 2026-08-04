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
| **UI** | `derrick.ui` | Chat, settings, approvals; XPC client; ensure peers up |
| **AgentService** | `derrick.ui.AgentService` | Agents, mailboxes, turns, memory; LLM; MCP now or Job later |
| **JobService** | `derrick.ui.JobService` | Durable jobs, schedules, retries; **RunTool** / **WakeAgent** |
| **MCPService** | `derrick.ui.MCPService` | Tool execution, policy principal, Docker path |
| **WebhookService** | `derrick.ui.WebhookService` | Public HTTP → CreateJob / RunTool / WakeAgent |
| **DockerHelper** | `derrick.ui.DockerRunnerHelper` | Constrained process runner (existing) |

**Packaging (locked):** Embedded **XPC services** in the app bundle first (same pattern as DockerHelper). Promote to LaunchAgents later if keep-alive without any app launch is required.

## Call rules

```
AgentService ──execute now──► MCPService
AgentService ──schedule─────► JobService ──at fire──► MCPService (RunTool)
                              JobService ──at fire──► AgentService (WakeAgent)
WebhookService ─────────────► JobService | AgentService | MCPService (bound intents only)
UI ─────────────────────────► Agent | Job | Webhook | health/start
```

- JobService / WebhookService never run LLM turns.
- Every MCP call carries a **principal** for policy.

### Job fire types
1. **RunTool** — frozen tool+args (+ approval ref); 0 LLM at fire.
2. **WakeAgent** — envelope → agent turn (may call MCP).
3. **RunToolThenWake** — tool then wake with result.

### AgentService
- May call **MCPService** immediately, or **JobService** to schedule.

## Ensure-up + health
1. `health()` → version + status.  
2. If connection fails → open XPC (launch-on-demand) → retry with backoff.  
3. Else error + point at `service_logs`.

## Auth (locked direction)
- **Peer:** code-sign requirement on XPC (extend `XPCPeerAuthentication`).
- **Message:** signed envelopes (`id`, `ts`, `from`, `to`, `type`, `payload`, `sig`) — HMAC with app-group key v1; upgrade path to asymmetric later.
- Webhook: separate external auth; only WebhookService listens publicly.

## Logging + DB (locked)
- **One shared SQLite** in host app container / app support (`derrick.sqlite3`).
- Multi-process access: **WAL** + **`busy_timeout=5000`** + **`synchronous=NORMAL`** on every open (`DBRepository`).
- Table ownership by domain; all services append **`service_logs`**.
- Domain: jobs tables (JobService), agents later (AgentService), existing memory/policy (today UI/Agent).

## Webhook liveness
- Self-health; bind fail → log + exit.
- **JobService** watchdog (when present); UI ensure-up on settings.

## P0 decisions (locked)

| # | Decision | Lock |
| --- | --- | --- |
| 1 | Packaging | **XPC services** embedded in app (LaunchAgent later if needed) |
| 2 | DB | **One shared SQLite**; multi-table ownership; WAL |
| 3 | Message auth | **HMAC app-group key** v1 + XPC peer identity |
| 4 | Idle | **Stay up while work**; may idle-exit after quiet period (v2) |
| 5 | Approval, UI absent | **Queue decision-needed**; job/agent wait with timeout → fail |

## Phases

| Phase | Status | Deliverable |
| --- | --- | --- |
| **P0** | done | This ADR + locked decisions |
| **P1** | partial | ServiceContracts; AgentService XPC; bootstrap+DB; UI ensure-up; **turn stream via XPC**; **UI is client-only** (no local ConversationModel for chat) |
| **P2** | partial | `service_logs` migration + writer; AgentService writes on bootstrap/health |
| **P3** | partial | MCPService XPC embed + UI ensure-up. Peer endpoint handoff: UI←MCP (XPC)→Agent (XPC). Effectors Agent→MCPService; `agents_*` local. |
| **P4** | pending | JobService |
| **P5** | pending | WebhookService |
| **P6** | pending | Persist agents, cancel trees, diagnostics UI |

## Out of scope
Society-of-mind free topology; replacing MCP; multi-agent on every task.
