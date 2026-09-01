# Slack connector plugin (Web API)

Use this when building a Derrick **connector** (`role: connector`) for Slack.

## Manifest

- `plugin_id`: `slack-connection` (or another lowercase hyphenated id)
- `role`: `connector`
- `secrets`: one field only for bot tokens:
  - `id`: `bot_token`
  - `label`: `Bot User OAuth Token`
  - `kind`: `token`

The host stores the token in Keychain and attaches `Authorization: Bearer <token>` to Slack HTTP calls. Never embed tokens in `swift_source`.

## Base URL

`https://slack.com/api/<method>` — GET or POST per method. Query params on GET; `application/x-www-form-urlencoded` body on POST.

## Response contract (required)

Every Slack Web API JSON body includes:

```json
{"ok": true, ...}
```

or

```json
{"ok": false, "error": "invalid_auth"}
```

**Rules the reviewer enforces:**

1. Parse the JSON `body` string from each `http_results` entry.
2. Treat success **only** when `ok` is boolean `true`.
3. When `ok` is false or missing, surface the `error` string (e.g. `invalid_auth`) in a `result.emit` error or failure envelope — never claim success.
4. Non-2xx HTTP status is failure even if JSON parses.

## Methods a Slack connector should support

| Operation | Method | Notes |
|-----------|--------|-------|
| Verify token | `auth.test` | GET; use on connect / health |
| List channels | `conversations.list` | `types=public_channel,private_channel`, `exclude_archived=true`, `limit=200` |
| Read messages | `conversations.history` | `channel`, `limit` (max 100) |
| Send message | `chat.postMessage` | POST `channel` + `text` |

## Pagination (required for list/history)

`conversations.list` and `conversations.history` may return `response_metadata.next_cursor` (list) or `has_more` + `response_metadata.next_cursor` (history).

Loop until the cursor is empty:

1. First request without `cursor`.
2. If `response_metadata.next_cursor` is a non-empty string, repeat with `cursor=<value>`.
3. Merge pages, sort by stable key (`name` for channels, `ts` for messages), de-duplicate.

Do not claim “all channels” or “full history” unless the code paginates.

## Suggested plugin stdin events

- `manual` or invoke: run `auth.test` and optionally list channels.
- Send path: `chat.postMessage` for outbound text.
- Receive path: `conversations.history` for a channel id supplied in the event.

## `test_input_json` and `http_results` fixtures (required)

The direct test must reach a **terminal** `result.emit` using fixtures that cover:

1. **Success** — `auth.test` with `"ok":true` and `user_id`.
2. **Auth failure** — any call with `"ok":false,"error":"invalid_auth"`; plugin must **not** report success.
3. **Send** — `chat.postMessage` with `"ok":true` and a `ts` field.
4. **Read** — `conversations.history` with a `messages` array (at least one message).
5. **Pagination** (if list/history is implemented) — first page with non-empty `next_cursor`, second page with empty cursor; merged output must include items from both pages.

Match each emitted `http.request` `request_id` to the corresponding `http_results` entry.

## Example auth failure fixture

```json
{"request_id":"auth-1","status":200,"body":"{\"ok\":false,\"error\":\"invalid_auth\"}","error":null}
```

## Example success fixture

```json
{"request_id":"auth-1","status":200,"body":"{\"ok\":true,\"user_id\":\"U123\",\"team\":\"T123\"}","error":null}
```
