# Contributing to Derrick

Thank you for your interest in contributing. Please read the [Code of Conduct](CODE_OF_CONDUCT.md).

## Requirements

- **macOS** with **Xcode 27** (Swift 6.4+)
- **Docker Desktop** (Swift script and plugin runtime; image `swiftlang/swift:nightly-6.4.x-noble`)
- Apple Developer account for code signing

## Getting started

1. Clone the repository.
2. Copy `.env.example` to `ui/ui/Resources/.env` and add your own API keys.
3. Configure signing (required if you are not the original maintainer):
   ```bash
   cp Config/Signing.xcconfig.example Config/Signing.xcconfig
   # Edit DERRICK_TEAM_ID and DERRICK_APP_GROUP
   ./scripts/configure-signing.sh
   ```
4. Open `derrick.xcworkspace` in Xcode.
5. Run the **`ui` scheme** only (not standalone `JobKeepAlive`).
6. Enable git hooks:
   ```bash
   git config core.hooksPath .githooks
   ```

See [docs/development.md](docs/development.md) for daemon bootstrap, Login Items, and database paths.

## Build from the command line

```bash
./scripts/build.sh          # build ui scheme + secret history scan
./scripts/build.sh test     # also run Swift package tests + ui tests
```

## Code signing

The repo ships with the maintainer's Team ID for convenience. Forks should run `./scripts/configure-signing.sh` after editing `Config/Signing.xcconfig`.

Files updated by the script include entitlements, `ServiceIdentity.swift`, `DerrickAppSupport.swift`, and `project.pbxproj`.

Do not commit provisioning profiles (`.mobileprovision`, `.p12`, `.pem`).

## Pull requests

- Run `./scripts/verify-no-secrets.sh --staged` before committing.
- Run `./scripts/build.sh test` when you change build-affecting code.
- Keep changes focused; match existing Swift style and module boundaries.
- Update README or ADRs when behavior or architecture changes.

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
