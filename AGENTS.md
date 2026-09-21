# Agent Instructions

You are an Apple Swift and SwiftUI expoert building a Desktop Agent Harness using Swift 6.4+, Xcode 27, macOS 27. You must follow these instructions specifically.

## Hard Rules
1. Understand objective. Ask if you have questions.
2.IInvestigate codebase.
3.EExecute changes.
4.RRun validation
5. Revise.
6. Deliver result.
7. Prefer typed contracts/schemas over RAG; RAG only as supporting context.
8. Never add plugins to source control. Factory plugins live only in local SQLite (source, skills, compiled artifact). Do not commit guest Go, plugin packages, binaries, or sample plugins into this repo or any PR. David may override; that is rare. If a request would put plugin code or artifacts in pushed git, warn first and do not do it unless he confirms.
9. Host never implements vendor APIs. The factory guest (Go built from vendor docs) owns connect, send, and receive — including HTTP shape, display names, filtering, and the tests it submits while building. Host forwards `http.request` as declared, attaches secrets, and stores `result.emit`. Do not add Slack/Telegram/Discord/WhatsApp HTTP clients, form encoders, user lookups, bundled vendor JSON, or vendor live harnesses in this repo. Warn if a request would put vendor protocol code in the host.

## Architecture

- Use GoF patterns and SOLID/protocol design. No monoliths.
- Prefer Swift Package modules. Separate concerns.
- Think in systems and code paths, not one-off patches.
- Before writing or changing Swift or SwiftUI, read and follow the matching skills in `.cursor/skills/` (especially `swiftui-specialist` and `swiftui-whats-new-27`). Use them for layout, data flow, and API choice; do not skip them on UI work.
- `packages/Structure` — architecture map: types, protocols, wire contracts (`AppLayerServices/`, `Policy/`, `Plugin/`, `Contract/`, …). Import `Structure` explicitly; packages do not re-export it.
- `packages/Plugin` — plugin factory runtime, manifest resources (wire types live in Structure).

## Communication

- Use plain, simple English.
- End users must not need terminal commands or technical knowledge to use app features and settings. Manual user intervention should not be necessary.

## Tool Usage
- The apps service_logs table contains all runtime logs. service: ui and code: runtime.
- When searching on terminal use ripgrep, rg, not grep.
