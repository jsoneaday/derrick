# handle() return (TypeScript + JSON)

Guest is TypeScript 7 on Bun. Stdout is a JSON array of envelopes.
Imports from `derrick`: `netFetch`, `httpBody`, `httpFailed`, `headlines`, `stripMarkup`. No `fetch`.

The `derrick` module source is attached in this prompt. That file is the SDK: `HandleEvent`, `HandleResult`, `PluginParams` field types, and helpers. Do not invent other handle or event shapes.

```typescript
interface PluginParams {} // your named fields only: string | number | boolean | string[] | number[]
export function handle(event: HandleEvent<PluginParams>): HandleResult
```

`HandleEvent<P>` — `P` is that object, not a union of values. Empty `PluginParams` is valid. The host fills `event` (`kind`, `http_results`, `params`); `params` may be omitted.

`any` is never allowed. `unknown` only after `typeof` / `in` / `instanceof`. No `as T`, no `@ts-ignore`.
First hop: `return netFetch({ url })`. On `http_results`: read `httpBody(event)`, return `result.emit` / `message.post`.
`title`, `summary`, and `text` are what the user reads: plain sentences or Markdown. Do not `JSON.stringify` the result into `summary`.
Verbs: `http.request` | `result.emit` | `message.post` | `ui.present` | `secret.request` | `job.schedule` | `log`
