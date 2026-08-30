# Local development

## Environment variables

Copy the repo-root `.env.example` to:

```
ui/ui/Resources/.env
```

Set `UI_SECRET_MODE=dotenv` for development. Production builds use Keychain for LLM and plugin secrets.

Never commit `.env`. The pre-commit hook blocks common secret patterns.

## Running the app

1. Open `derrick.xcworkspace`.
2. Select the **`ui`** scheme and run (⌘R).
3. Docker Desktop must be running for script/plugin execution.
4. The headless daemon (`derrickd`) starts via Login Items embedded in the app bundle.

Do **not** run `Products/Debug/JobKeepAlive.app` directly — it shares the database with the main app.

## SQLite (debug)

Default database path (app group container):

```
~/Library/Group Containers/<TEAM_ID>.derrick.shared/Library/Application Support/ui/derrick.sqlite3
```

Replace `<TEAM_ID>` with your Apple Team ID (see `Config/Signing.xcconfig`).

Inspect schema:

```bash
sqlite3 "$HOME/Library/Group Containers/<TEAM_ID>.derrick.shared/Library/Application Support/ui/derrick.sqlite3" '.schema'
```

## Daemon & Login Items

- `derrickd` runs inside `Derrick.app/Contents/Library/LoginItems/JobKeepAlive.app`.
- macOS may require **Background App Activity** enabled for Derrick in System Settings.
- If bootstrap fails, quit and relaunch the main app — do not run a standalone `JobKeepAlive` build from Products.

## Docker

- Docker Desktop must be running before chat tools or plugin execution.
- Guest Swift uses `swiftlang/swift:nightly-6.4.x-noble` with `--network none` (see [adr-swift-script-runtime.md](adr-swift-script-runtime.md)).

## Secret scanning

```bash
git config core.hooksPath .githooks
./scripts/verify-no-secrets.sh --staged
./scripts/verify-no-secrets.sh --history
```
