# ADR: Docker-only Bun script runtime (one container style)

**Status:** Accepted  
**Date:** 2026-08-13  
**Supersedes:** [adr-docker-script-runtime.md](adr-docker-script-runtime.md) (prior guest language, dual pools, in-container CONNECT)

## Context

Product lock (2026-08-13, guest TS 2026-08-15): **one container style** for one-off scripts and complementary plugins. Runtime is **Bun + TypeScript 7** (native Go `tsc` from `typescript@7`). The guest SDK is `ui/SharedAgentRuntime/Resources/guest/derrick.ts` (same verbs as `handle-return.schema.json`). `tsc --noEmit` runs in the guest before handoff; failures abort with compiler output. User code never has a network stack. HTTP and UI are JSON messages handled by Swift. Playwright is a **separate** browser-UI tool (not in this image).

The superseded ADR records the earlier guest language and CONNECT-allowlist path.

## Decision

| Item | Lock |
| --- | --- |
| Runtime | Bun + TypeScript 7 (Go `tsc`). Types generated from host JSON Schema. |
| Image | Single baseline (`derrick-bun:baseline-4`). |
| Pool | **One** Docker pool. Per-lease create; destroy after user code. Same TTL class (`ContainerLifecyclePolicy`). |
| Run network | `--network none`. No `HTTP_PROXY`. No `host.docker.internal` add-host. |
| Setup network | Allowed **only** for `bun install` of LLM-declared packages (install hooks **may** run). Then disconnect / recreate none. Then handoff. |
| HTTP | Host `PluginHTTPClient` (scripts and plugins). Egress policy sits **in front of Swift**, not in the container. |
| Egress | Keep `packages/EgressProxy` **policy + prompts**. Soft list is a **blacklist** (empty at first launch). Hard SSRF never overridable. CONNECT `:18080` is unused on the run path. |
| Review | Scripts: every run. Plugins: once, then `content_hash`. |
| Helper | `DockerRunnerHelper` remains the only `docker` CLI process. Volume I/O is `create`/`start`/`exec`/`rm` only. |
| Apple Container | Still forbidden. |

## Two-phase lease

1. **Setup** (network on): write declared `package.json` / lockfile; `bun install` (author `preinstall`/`install`/`postinstall` hooks allowed). Residual supply-chain risk accepted.
2. **Cut network** (`docker network disconnect` or destroy + recreate `--network none` with the same volumes).
3. **Handoff:** `handle(event)` / one-shot script. `fetch` / `net` / `Bun.connect` must fail. Only `derrick.net.fetch` → stdout JSON → Swift.

## Non-goals

- Chromium / Playwright / Crawlee in this image
- Official vendor SDKs that open sockets
- Dual guest-language routers
- Apple Container

## References

- [software-factory.md](software-factory.md) — factory + unified runtime plan
- [adr-headless-backend.md](adr-headless-backend.md)
- [adr-docker-script-runtime.md](adr-docker-script-runtime.md) — superseded runtime decision
