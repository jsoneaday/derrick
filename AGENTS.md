# Agent Instructions

Desktop Agent Harness. Swift 6.4+, Xcode 27, macOS 27.

## Critical — do not violate

- Run the **`ui` scheme only** for app work.
- Do **not** launch `Products/Debug/JobKeepAlive.app`. It shares the database and steals scheduled jobs. `derrickd` starts via Login Items when you run the main app (`Derrick.app/Contents/Library/LoginItems/JobKeepAlive.app`). The `JobKeepAlive` scheme is build-only (⌘R builds, does not launch).

## Guest contract (language-agnostic)

The guest ↔ host boundary is **JSON Schema**, not Swift. Canonical schemas live in:

`packages/Structure/Sources/Contract/Resources/schemas/`

| Schema | Direction | Swift types (must stay in sync) |
|--------|-----------|----------------------------------|
| `hop-event.schema.json` | Host → guest (stdin) | `PluginHopEvent`, `PluginEventKind` |
| `envelope-list.schema.json` | Guest → host (stdout) | `PluginVerb`, `PluginEnvelope` |

**When you change any schema file, you must update the matching Swift types and tests in the same change.** There is no Xcode codegen for this — edit both by hand. `GuestContractAlignmentTests` (Plugin) and `GuestContractTests` (Structure) fail if schema enums and Swift enums drift.

Validate at boundaries with `GuestContractValidation` before decoding.

### Container profiles (target architecture)

| Profile | Network | Examples |
|---------|---------|----------|
| **Network** | Yes (proxied) | `web.crawl` — fixed crawler image |
| **Offline guest** | No (`--network none`) | `script_exec` + `plugin.invoke` — **consolidate into one guest runtime** with ephemeral vs packaged entry modes |

Offline guests may be implemented in **Python** (primary target) or Swift (legacy). The host broker (HTTP, secrets, hop loop) stays Swift.

**Python guest image** (`docker/guest-runtime/Dockerfile`): base on `python:3.14.7`, install **[uv](https://github.com/astral-sh/uv)** for packaged plugin dependencies (`COPY --from=ghcr.io/astral-sh/uv:latest`). `script_exec` uses the pullable `python:3.14.7` image today; the custom `derrick-guest-runtime:python-v1` image is for connector plugins with baked deps.

Do not add host-owned vendor API clients (e.g. Slack-specific Web API) for connectors — vendors belong in guest plugins.

## Before changing code

- Read the files on the code path you are changing. Do not guess.
- Check `Info.plist` and app configuration before assuming a code bug.
- Send the model the context it needs **before** asking it to produce output.
- Fix issues at the root cause. No band-aid fixes.

## Architecture

- Use GoF patterns and SOLID/protocol design. No monoliths.
- Prefer Swift Package modules. Separate concerns.
- Think in systems and code paths, not one-off patches.
- `packages/Structure` — architecture map: types, protocols, wire contracts (`AppLayerServices/`, `Policy/`, `Plugin/`, `Contract/`, …). Import `Structure` explicitly; packages do not re-export it.
- `packages/Plugin` — plugin factory runtime, manifest resources (wire types live in Structure).

## Before finishing

- Add or update unit tests and e2e tests when new code over 5 lines is added.
- Verify the app builds and launches cleanly on the `ui` scheme.
- Make sure all tests pass after any change over 5 lines.

## Communication

- Use plain, simple English.
- End users must not need terminal commands or technical knowledge to use app features and settings. Manual user intervention should not be necessary.

## Tool Usage
- The apps service\_logs table contains all runtime logs. service: ui and code: runtime.
- When searching on terminal use ripgrep, rg, not grep.
