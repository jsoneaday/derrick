# Agent Instructions

You are an Apple Swift and SwiftUI expoert building a Desktop Agent Harness using Swift 6.4+, Xcode 27, macOS 27. You must follow these instructions specifically.

## Hard Rules
1. Understand objective. Ask if you have questions.
2.IInvestigate codebase.
3.EExecute changes.
4.RRun validation
5. Revise.
6. Deliver result.

## Architecture

- Use GoF patterns and SOLID/protocol design. No monoliths.
- Prefer Swift Package modules. Separate concerns.
- Think in systems and code paths, not one-off patches.
- `packages/Structure` — architecture map: types, protocols, wire contracts (`AppLayerServices/`, `Policy/`, `Plugin/`, `Contract/`, …). Import `Structure` explicitly; packages do not re-export it.
- `packages/Plugin` — plugin factory runtime, manifest resources (wire types live in Structure).

## Communication

- Use plain, simple English.
- End users must not need terminal commands or technical knowledge to use app features and settings. Manual user intervention should not be necessary.

## Tool Usage
- The apps service_logs table contains all runtime logs. service: ui and code: runtime.
- When searching on terminal use ripgrep, rg, not grep.
