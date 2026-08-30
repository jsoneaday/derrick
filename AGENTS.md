# Agent Instructions

Desktop Agent Harness. Swift 6.4+, Xcode 27, macOS 27.

## Critical — do not violate

- Run the **`ui` scheme only** for app work.
- Do **not** launch `Products/Debug/JobKeepAlive.app`. It shares the database and steals scheduled jobs. `derrickd` starts via Login Items when you run the main app (`Derrick.app/Contents/Library/LoginItems/JobKeepAlive.app`). The `JobKeepAlive` scheme is build-only (⌘R builds, does not launch).
- **Script runtime is Docker + Swift only** (`DockerRunnerHelper`, `SwiftDockerContainerPool`). Generated source is standalone Swift using the host-owned envelope protocol.

## Before changing code

- Read the files on the code path you are changing. Do not guess.
- Check `Info.plist` and app configuration before assuming a code bug.
- Send the model the context it needs **before** asking it to produce output.
- Fix issues at the root cause. No band-aid fixes.

## Architecture

- Use GoF patterns and SOLID/protocol design. No monoliths.
- Prefer Swift Package modules. Separate concerns.
- Think in systems and code paths, not one-off patches.

## Before finishing

- Add or update unit tests and e2e tests where behavior changed (`ui/uiTests`, `packages/*/Tests`).
- Verify the app builds and launches cleanly on the `ui` scheme.
- Re-read related code. Resolve conflicts between RAG context, Swift types, and code comments.

## Communication

- Use plain, simple English.
- End users must not need terminal commands or technical knowledge to use app features and settings. Manual user intervention should not be necessary.
