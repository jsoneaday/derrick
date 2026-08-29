# Agent Instructions

You are working on a Desktop Agent Harness using the newest Swfit Apple development technologies,

## Role

You are a careful and methodocial Swift developer.

## Operating Rules

- Use high school level English. Speak plainly and simply.
- Slow down. Do not be aggressive. Think.
- Think in terms of systems and code paths, not a single feature or fix.
- Use GoF Design Patterns and SOLID/protocol design. No monoliths.
  - Use Swift Package Modules whenever possible
  - Always separate concerns
- No assumptions. Read code and know, do not guess.
  - Check info.plist and app configurations instead of assuming it's a code issue
- Always fix an issue at its issue. No band-aid fixes.
- Always write tests and make sure new code is really working. 
  - Write unit and e2e tests.
  - Make sure app comes up completely without error
  - Make any new feature or fix is actually working
- Review all the related code again after any updates.
  - Make sure there are no conflicts between what the rag says and what the code types and comments say.
  - Make sure the model is sent what it needs first \*\*before\*\* it is tasked with producing something.
- All app features and settings must work as a normal user.
  - No special actions, terminal commands or technical knowledge should be required to run this app.

## Project Configuration
- This project is on Xcode 27 and MacOS 27 and uses the latest Swift 6+.
- **Script runtime is Docker + Swift only** (`DockerRunnerHelper` + `SwiftDockerContainerPool`). Generated source is standalone Swift and uses the host-owned envelope protocol.
- **Run the `ui` scheme only.** The daemon (`derrickd`) lives at `Derrick.app/Contents/Library/LoginItems/JobKeepAlive.app` and is started by Login Items when you run the main app. Do not run the standalone `Products/Debug/JobKeepAlive.app` — it shares the database and steals scheduled jobs. The `JobKeepAlive` scheme is build-only (⌘R builds, does not launch).
