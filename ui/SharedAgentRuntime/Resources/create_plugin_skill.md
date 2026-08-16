# Create a complementary plugin

Tools, in order: `factory.build` → `factory.write_package` → `factory.review` → `factory.test` → `factory.promote`.
Do not `complete` before `factory.promote`. Do not call `tool_search`. There is no `plugin.install`.

- `factory.build` — required `goal` (the user's request). If the result has `ask_user`, ask which plugin, then `factory.build` again. If it has `reuse_plugin_id`, that is `plugin_id`.
- `factory.write_package` — `plugin_id`, `description`, `handle`. Optional `version`, `dependencies`, `volume_enabled`, `fixtures`.
- `factory.review`, `factory.test` — no arguments.
- `factory.promote` — user approves install. Host hashes and stores one version.

The attached `derrick.ts` file is the guest SDK (`import { … } from "derrick"`). Types and helpers live there. Do not invent other handle or event shapes.

```typescript
interface PluginParams {} // named fields only: string, number, boolean, string[], number[]
export function handle(event: HandleEvent<PluginParams>): HandleResult
```

Empty `PluginParams` is valid. `handle` must work when `event.params` is omitted. The host builds `event` and calls `handle`. You do not instantiate `event`.
`title`, `summary`, and `text` are what the user reads: Markdown or plain sentences. Do not `JSON.stringify` the result into `summary`.
`volume_enabled` only if the plugin needs `/data`.
