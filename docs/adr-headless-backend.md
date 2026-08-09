# ADR: Headless backend (`derrickd`)

**Status:** Accepted  
**Date:** 2026-08-08

## Context

The UI + multiple embedded XPC services (Agent, Job, MCP) + JobKeepAlive created an in-app distributed system: peer-mesh handoffs, lifecycle coupling to the UI process, and no reliable owner for UserNotifications when the UI is closed.

## Decision

| Process | Role |
| --- | --- |
| **`derrick.ui`** | Sandboxed SwiftUI client only |
| **`derrick.ui.Daemon` (`derrickd`)** | Unsandboxed LoginAgent: Agent + Jobs + MCP host + AppEventBus + **sole** notification poster |
| **`derrick.ui.DockerRunnerHelper`** | Remains external constrained runner |
| Docker Engine | Remains external |

- UI ↔ Daemon: **XPC** over Mach service `VUSK4B2YKQ.derrick.shared.daemon` (app-group child — required for sandboxed UI `mach-lookup`)
- Daemon ↔ Docker helper: **XPC** (existing)
- Inside Daemon: **in-process** modules (no XPC between agent/job/mcp)
- LaunchAgent **Label** remains `derrick.ui.Daemon`; embedded SM plist is `derrick.ui.Daemon.plist`
- Daemon is an **LSUIElement app** at `Contents/Library/LoginItems/JobKeepAlive.app` (bare tools cannot obtain UserNotifications TCC)

## Notification rule

Only the Daemon process posts `UNUserNotificationCenter` notifications. Other code uses `NotificationSender` which XPC-forwards to the Daemon when not in-process.

## Migration

1. Stand up Daemon (health, bootstrap, notify, event bus) — **this ADR**
2. Fold Job scheduler/executor into Daemon
3. Fold Agent turns into Daemon
4. Fold MCP tool host into Daemon
5. Remove AgentService / JobService / MCPService `.xpc` targets and peer mesh
6. UI ensure-up → single `ensureDaemon()`
7. Job completion → `JobResultNotifier` → Daemon `UNUserNotificationCenter` (done); retire UI poll/wake for job results
8. Fold HITL notify posting into Daemon
9. Until Job/Agent live in-daemon: derrickd job watchdog wakes `--derrick-job-worker` when UI is quit and jobs are due

## Non-goals

- Sandboxing the Daemon (LaunchAgent + App Sandbox is unreliable; tool isolation stays in Docker)
- Multi-user system daemons (login session only)
