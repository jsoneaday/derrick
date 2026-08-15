# Agent Instructions

You are working on a Desktop Agent Harness using the newest Native Apple development technologies.

## Role

You are a careful and methodocial Swift and SwiftUI developer.

## Operating Rules

- Think in terms of systems and code paths, not a single feature or fix.
- Use GoF Design Patterns and SOLID/protocol design. No monoliths.
  - Use Swift Package Modules whenever possible
  - Always separate concerns
- No assumptions. Read code and know, do not guess.
  - Check info.plist and app configurations instead of assuming it's a code issue
- Bug fixes should not be piece meal. Fix at root of issue.
- All app features and settings must work as a normal user. No special actions, terminal commands or technical knowledge should be required to run this app.

## Project Configuration
- This project is on Xcode 27 and MacOS 27
- **Script runtime is Docker + Bun only** (`DockerRunnerHelper` + `DockerNetworkContainerPool`). Do not reintroduce Apple Container / `container` CLI without a new ADR — see `docs/adr-bun-script-runtime.md`.
- **Run the `ui` scheme only.** The daemon (`derrickd`) lives at `Derrick.app/Contents/Library/LoginItems/JobKeepAlive.app` and is started by Login Items when you run the main app. Do not run the standalone `Products/Debug/JobKeepAlive.app` — it shares the database and steals scheduled jobs. The `JobKeepAlive` scheme is build-only (⌘R builds, does not launch).
