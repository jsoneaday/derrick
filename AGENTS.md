# Agent Instructions

Desktop Agent Harness. Swift 6.4+, Xcode 27, macOS 27.


## Before changing code

- Read the files on the code path you are changing. Do not guess.
- Check `Info.plist` and app configuration before assuming a code bug.
- Find the root cause of an issue. Do not assume or guess. Then and only then proceed to create a solution.
- All services must follow the Protocols in the Structure spm or update them.

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
- The apps service_logs table contains all runtime logs. service: ui and code: runtime.
- When searching on terminal use ripgrep, rg, not grep.
