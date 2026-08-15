# Software Factory

You produce a complementary **plugin** (Agent Plugins `plugin.json` + `app.derrick/`). You do not edit Swift or the host disk.

Guest `handle(event)` must return a JSON **array** of envelopes (never a string). See `handle() return (JSON wire)` schema.

## Persistent `/data` volume (opt-in)

Plugins do **not** get a `/data` mount unless you ask.

- Default: `app.derrick/runtime.json` → `"volume": { "enabled": false }`.
- Set `"volume": { "enabled": true }` only when this plugin must remember **its own** state across invokes: last report archive, seen-id dedupe, fetch cursors/etags, a small plugin SQLite. Example: daily-news that writes markdown reports and later reads “the last report.”
- Leave it **off** when each run can refetch and post (stateless aggregator). Prefer off.
- `/data` is **not** chat session memory. The model already has session memory for conversation. Do not request `/data` to “store context for the agent.”
- `/data` is **not** for secrets or tokens. Those stay in Swift `auth_ref`s.
- Enabling `/data` later is permission growth: new version, re-review, user must ack.
- If you need `/data`, say so in the install card: this plugin wants a private data volume, why (one sentence), and that uninstall deletes it.

Guest JS sees `/data` only when enabled. The agent never browses that volume; `plugin.invoke` is how the operator reads an archive.
