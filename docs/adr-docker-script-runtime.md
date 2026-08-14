# ADR: Docker-only guest script runtime (archived)

**Status:** Superseded  
**Date:** 2026-08-11  
**Superseded by:** [adr-bun-script-runtime.md](adr-bun-script-runtime.md) (2026-08-13) — Bun, one container style, host-side blacklist egress  
**Supersedes:** Experimental Apple Container (`Containerization` / `container` CLI) integration (never shipped)

This file is an archive of the previous guest-language decision. Do not implement from it.

## Context

Derrick runs untrusted Python via `python_script_exec`. We evaluated two backends:

| Backend | Pros | Cons observed |
| --- | --- | --- |
| **Docker Desktop** | Mature networking (`--network none`, egress hold), Playwright/Chromium bake, existing `DockerRunnerHelper` XPC path | Requires Docker Desktop; external daemon |
| **Apple Container** (`container` CLI) | Native on macOS; no Docker Desktop dependency | Fragile bootstrap (kernel/daemon drift, stuck builds), immature ops vs Docker path, duplicated pool/image logic |

An Apple Container spike (`ContainerRuntime` package, `AppleContainerScriptRunner`, runtime router, Settings picker) was built and **removed** before release. Production returned to Docker only.

## Decision

**Python script execution uses Docker only.**

| Component | Role |
| --- | --- |
| `DockerRunnerHelper` (XPC) | Runs `docker` CLI in a constrained helper process |
| `DockerNetworkContainerPool` | Queued pools: network max 2 (1 warm), offline max 1; destroy/recreate after runs |
| `DockerScriptPreparer` | Image build, exec wrapper, baseline packages (Crawlee/Playwright) |
| `ContainerLifecycleSettings` | User-configurable container run TTL (Settings → Containers) |

There is **no** `ScriptRuntimeBackend`, **no** Apple Container bootstrap, and **no** `container` CLI integration in the product.

## Container policy (locked)

Documented in `ContainerLifecyclePolicy.derrickDefault` and enforced by `DockerNetworkContainerPool`:

- **Network** (`allow_network=true`): max 2 alive, 1 warm standby, FIFO queue when busy
- **Offline** (`allow_network=false`): max 1 alive, on-demand create/destroy, FIFO queue
- **Lease TTL**: configurable (default 7 minutes); queue wait excluded
- **Isolation**: exclusive slot per run; container recreated or destroyed after user code — never reused in place

## Non-goals

- Shipping Apple Container as an alternate or automatic backend
- Dual image/runtime routers (`MCPServiceScriptRunnerRouter`-style)
- User-facing “Python runtime” picker between Docker and Apple Container

## Revisit criteria

Re-open Apple Container only if **all** are true:

1. `container` CLI + daemon are stable on supported macOS without manual kernel/daemon repair
2. Network isolation (`--network none` equivalent) and egress policy parity with Docker path
3. Playwright/Chromium cold-start time is acceptable vs current Docker baseline image
4. A single pool implementation can be shared — no parallel `ContainerRuntime` package fork

Until then, invest in Docker pool hardening (queue, TTL, tests) — not a second runtime.

## References

- [adr-headless-backend.md](adr-headless-backend.md) — Docker helper remains external constrained runner
- [services-plan.md](services-plan.md) — MCP docker via `DockerRunnerHelper` peer XPC
