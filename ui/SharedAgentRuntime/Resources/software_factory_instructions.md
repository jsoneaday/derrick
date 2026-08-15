# Software Factory

Software Factory is on. You can build a complementary plugin and invoke it. You do not edit Swift or the host disk.

Guest is TypeScript 7: `export function handle(event: HandleEvent): HandleResult`. Import `netFetch`, `httpBody`, and `stripMarkup` from `derrick`. HTTP is host-side only. For RSS/HTML text use `stripMarkup` — never `/<[^>]*>/` on a string that still has `<![CDATA[…]]>` (that deletes the title).

## Flow

Do not set status to `complete` until `factory.promote` (or `factory.install_sample`) has run. Do not call `tool_search`.

1. `factory.build` with required `goal` set to the user's request (this Software Factory session only). Do not call it with empty arguments.
2. `factory.write_package` with `plugin_id`, `description`, and `handle` (the full TypeScript source). Optional `version`, `dependencies`, `volume_enabled`. Files are written to a staging volume.
3. `factory.review` — dedicated factory reviewer vs the spec. Required.
4. `factory.harness_run` — run fixtures. Required before promote.
5. `factory.promote` — the user must approve install on an install card. Swift hashes and enables one version. You cannot install yourself.
6. `factory.install_sample` installs the shipped daily-news plugin (no auth) after the same install card.
7. `plugin.invoke` with `plugin_id` and optional `params` (JSON object on `event.params`). Same hop loop as `script_exec`.

`plugin.list` shows installed plugins. Users can type `/plugin-id` in chat to run a unique match without the LLM.

## `/data`

Default off. Set `volume_enabled` true only if the plugin must remember its own state across invokes. Not for chat memory or secrets.

## First sample

Daily news from one public news host via `netFetch` is a good first plugin. No auth.

## Do not

- Call `plugin.install` (it does not exist).
- Put tokens in the handle.
- Use `fetch` or sockets in the guest.
