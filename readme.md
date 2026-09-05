# Derrick

A native Swift macOS 27 desktop agent harness: chat with LLM providers, run isolated sandboxed agent actions in Docker, build connector plugins, schedule background jobs, and manage messaging connectors — with human-in-the-loop approvals and a security-first execution model.

**License:** [Apache 2.0](LICENSE)

## What it does

| Area | Description |
|------|-------------|
| **Chat** | Multi-tab conversations with OpenAI, Gemini, and other configured models |
| **Tools (MCP)** | Model Context Protocol tool host inside the headless daemon |
| **Scripts** | Agent-generated Swift executed in isolated Docker containers  Includes secondary agent code reviewer and approvals flow.|
| **Plugin factory** | LLM-assisted creation of versioned, reviewed connector plugins |
| **Jobs** | Scheduled and deferred tool/agent runs that survive app quit |
| **Messaging** | Connector plugins (e.g. Slack) with threads, history, and live sync |
| **Policy & HITL** | Approvals for tools, network access, usage limits, and credentials |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Derrick.app (UI) — SwiftUI client only                     │
│  Chat · Messaging · Plugins · Settings · Approval modals      │
└───────────────────────────┬─────────────────────────────────┘
                            │ Mach XPC (signed messages)
┌───────────────────────────▼─────────────────────────────────┐
│  derrickd (JobKeepAlive Login Item)                         │
│  Agent turns · Job scheduler · MCP tool host · Notifications│
└───────────────┬─────────────────────────┬───────────────────┘
                │ in-process              │ XPC
        ┌───────▼────────┐        ┌───────▼──────────────────┐
        │ SQLite (WAL)   │        │ DockerRunnerHelper XPC │
        │ shared state   │        │ docker CLI + pool      │
        └────────────────┘        └───────────┬────────────┘
                                                │
                                    ┌───────────▼────────────┐
                                    │ Swift guest containers │
                                    │ --network none         │
                                    └────────────────────────┘
```

- **UI** is a client: it does not own agent turns or MCP when the daemon is up.
- **Daemon** (`derrickd`) is the single owner of OS notifications and in-process Agent/Job/MCP modules.
- **Docker** runs untrusted Swift for `script_exec`, plugin factory builds, and approved plugin invocations.

See [docs/adr-headless-backend.md](docs/adr-headless-backend.md) and [docs/services-plan.md](docs/services-plan.md).

## Security model

Derrick treats model output and guest code as untrusted.

### Docker sandbox (Swift runtime)

- Guest programs run in `swiftlang/swift:nightly` containers with **`--network none`**.
- No shell, `Process`, `URLSession`, or credentials inside the guest.
- The host dispatches `http.request` envelopes, attaches secrets, and enforces egress policy.
- Documented in [docs/adr-swift-script-runtime.md](docs/adr-swift-script-runtime.md).

### Script review agent

Before `script_exec` writes to disk, a **configured LLM reviewer** checks:

- Intent alignment with the user request
- No secret literals in source
- Safe handling of fetched content (no raw HTML leakage unless requested)

Instructions live in `ui/SharedAgentRuntime/Resources/script_reviewer_instructions.md`. A static **Swift verifier** also rejects forbidden APIs.

### Egress & network

- Host-owned HTTP (`HostHTTPClient`) with **egress blacklist** (persisted in SQLite).
- New destinations can require **user approval** (HITL network access modal).
- Plugins never receive tokens; `PluginDeclaredSecretAttacher` adds Bearer/Basic headers on the host.

### Secrets

| Context | Storage |
|---------|---------|
| LLM API keys (dev) | `ui/ui/Resources/.env` when `UI_SECRET_MODE=dotenv` |
| LLM API keys (release) | Keychain |
| Plugin connector tokens | Keychain (`PluginSecretKeychain`) or `.env` aliases in dev |
| Inter-service XPC (debug) | `MESSAGES_SECRET_KEY` in `.env` |
| Inter-service XPC (release) | Keychain (`MessagesSecretKey`) |

Copy [.env.example](.env.example) — **never commit `.env`**.

### Human in the loop (HITL)

- Tool execution approvals
- Network access requests
- Plugin credential collection (Keychain save)
- Policy events (usage limits, content sensitivity)

### Policy

- **`PolicyEngine`** — in-process tool-call rules for chat (`Structure/Policy/PolicyEngine`).
- **`PolicyRuntime`** — persisted rules from SQLite (`Structure/Policy/PolicyRuntime`); implemented by `StoreBacked*` evaluators in `packages/PolicyRuntime`.
- **`PolicyInterceptor`** / **`ToolRequestInterceptor`** (MemorySystem) — pipeline hooks that call those policies.

### Messaging

Connector plugins declare `role: connector` in the manifest. Messages are persisted in SQLite; connector plugins sync and send through the guest runtime. See [docs/messaging-design.md](docs/messaging-design.md).

## Repository layout

| Path | Role |
|------|------|
| `ui/` | macOS app, Login Item daemon, XPC services |
| `packages/DBRepository` | SQLite schema, migrations, messaging tables |
| `packages/MCPServer` | MCP bridge, script execution, plugin runtime |
| `packages/Structure` | Architecture map: wire types, protocols, JSON schemas (`AppLayerServices/`, `Policy/`, `Plugin/`, `Contract/`, …) |
| `packages/Plugin` | Plugin factory runtime and bundled skill/reviewer resources |
| `packages/DerrickBackend` | Daemon runtime, notifications, HITL polling |
| `packages/DockerRunnerXPC` | Constrained Docker helper |
| `packages/PolicyRuntime` | Store-backed policy evaluators (`Structure/Policy/PolicyRuntime`) |
| `packages/LLMAgentClient` | Provider clients (OpenAI, Gemini, …) |

## Quick start

### Prerequisites

- macOS 27 with **Xcode 27** (Swift 6.4+)
- Docker Desktop
- Apple Developer account (for signing entitlements)

### Build & run

1. Clone the repo.
2. `cp .env.example ui/ui/Resources/.env` and add your API keys.
3. (Forks) `cp Config/Signing.xcconfig.example Config/Signing.xcconfig` and run `./scripts/configure-signing.sh`.
4. Open `derrick.xcworkspace`, select the **`ui`** scheme, Run (⌘R).
5. Enable secret hooks:
   ```bash
   git config core.hooksPath .githooks
   ```

Or from the terminal: `./scripts/build.sh test`

See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/development.md](docs/development.md).

## Open-sourcing checklist

We maintain [docs/opensource-plan.md](docs/opensource-plan.md) for pre-release cleanup (secret audit, personal reference removal, CI).

Verify no secrets in git:

```bash
./scripts/verify-no-secrets.sh --history
```

## Documentation

- [Headless backend ADR](docs/adr-headless-backend.md)
- [Swift Docker runtime ADR](docs/adr-swift-script-runtime.md)
- [Background services plan](docs/services-plan.md)
- [Messaging design](docs/messaging-design.md)
- [Security policy](SECURITY.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)

## Trademark

“Derrick” is the project name used in this repository. Third-party names (OpenAI, Google, Slack, Docker, etc.) are trademarks of their respective owners.

## Agent / contributor notes

See [AGENTS.md](AGENTS.md) for conventions used by coding agents working in this repo.
