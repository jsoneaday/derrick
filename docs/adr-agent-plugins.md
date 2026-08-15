# ADR: Agent Plugins 1.0 as the plugin package format

**Status:** Accepted  
**Date:** 2026-08-14  
**Spec:** [Agent Plugins 1.0.0](https://agent-plugins.org/specification)  
**Skills:** [Agent Skills](https://agentskills.io/specification)  
**Supersedes:** custom root `manifest.json` in [software-factory.md](software-factory.md) §4

## Context

Derrick’s factory was going to invent its own plugin tree (`manifest.json` + `plugin.js` + Derrick-only fields at the root). In August 2026, Agent Plugins 1.0.0 became the vendor-neutral package format for **Agent Skills** and **MCP servers** (TSC: Amazon, Cursor, Microsoft, OpenAI, Vercel; Google joined).

That spec is a **folder shape and a closed `plugin.json`**. It does not define install, permissions, sandboxing, trust, or UX. Those stay Derrick’s.

## Decision

1. An installed complementary plugin **is** an Agent Plugin directory.
2. Root manifest is **only** standard `plugin.json` (closed schema). Derrick fields are **not** top-level.
3. Derrick-only runtime data lives under the client extension namespace **`app.derrick`** (manifest `extensions` and/or the `app.derrick/` directory). This is the product name, not the `derrick.ui` bundle identifier (that stays until a signing migration).
4. Portable components we will load:
   - **Skills** (`skills/*/SKILL.md`) — when/how the agent should use the plugin.
   - **MCP** (`mcp.json`) — later / imported third-party plugins. Factory-generated plugins **omit** `mcp.json` in v1.
5. Execution of guest JavaScript stays the existing Bun two-phase lease (`handle` → JSON messages → Swift). That is **not** in the Agent Plugins spec; it is our client extension.
6. `script_exec` is still a one-shot tool, not a plugin package.

## Package layout

```text
daily-news/
├── plugin.json                 # Agent Plugins 1.0 only
├── skills/
│   └── daily-news/
│       └── SKILL.md            # Agent Skills format
└── app.derrick/
    ├── runtime.json            # triggers, auth_refs, quotas, deps
    ├── plugin.js               # export function handle(event)
    └── bun.lock                # required if dependencies nonempty
```

### `plugin.json` (portable)

```json
{
  "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
  "name": "daily-news",
  "version": "1.0.0",
  "description": "Headlines from one news host.",
  "extensions": {
    "app.derrick": {
      "entrypoint": "./app.derrick/plugin.js",
      "runtime": "./app.derrick/runtime.json"
    }
  }
}
```

`name` follows Agent Plugins rules (1–64 chars, `a-z` `0-9` `-` `.`, no `--` / `..`).

### `app.derrick/runtime.json` (ours)

Triggers, `auth_refs`, UI surfaces, job/schedule flags, volume quota, HTTP quotas, declared npm `dependencies`. Same product rules as the old custom manifest, just not at the package root.

Guest JS still has no sockets. HTTP and cards stay host verbs.

### What we will not do in v1

| Idea | Why not |
| --- | --- |
| Treat `skills/*/scripts/` as host-runnable | Untrusted. Scripts in a skill are docs/helpers for the model, not a host shell. |
| Factory emits `mcp.json` stdio servers | Would launch an executable from generated code. Our MCP tools stay in Derrick (`plugin.invoke`). |
| Put Derrick fields on `plugin.json` | Closed schema; unknown top-level fields have no meaning. |
| Replace Bun sandbox with “just a skill” | Skills are instructions. Complementary features still need the isolated `handle()` runtime. |

## Client conformance (minimum)

Derrick will:

- Load a plugin from a directory (named volume / install path).
- Validate `plugin.json` for `$schema` `https://agent-plugins.org/schemas/1.0.0/plugin.schema.json`.
- Ignore other `extensions.*` namespaces.
- Discover skills under `skills/` (skip invalid ones).
- Reject paths that escape the plugin root.
- `PLUGIN_DATA` (`/data`) is **opt-in** (`app.derrick/runtime.json` `volume.enabled`, default false). Maps to the spec’s client-managed data dir when enabled. We do **not** put that path in the guest environment as a host filesystem path.

We are a **skills + Derrick-runtime** client first. MCP-in-plugin is optional later.

## Consequences

- PR 1 contract types parse Agent Plugins `plugin.json` + `app.derrick` runtime, not a custom root manifest.
- Factory promote writes a valid Agent Plugin tree and hashes that tree.
- Third-party Agent Plugins that are skills-only can be installed; without `app.derrick` they are prompt/skill packs only (no sandboxed `handle`).
- Playwright / browser automation stays unrelated (PR 16).
