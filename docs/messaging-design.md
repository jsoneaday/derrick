# Messaging design notes

Saved from chat on 24 Aug 2026 so it survives reboot. Inbound UX locked 27 Aug 2026. Not implemented yet.

The menu, thread tabs, and archive are the right product. A Docker webhook that Slack/Telegram push into is the wrong receive path for this app.

## What already exists

Chat already has tabs (`ChatSessionStore`). Plugins already sit in the sidebar. The guest already speaks `PluginHopEvent` (`manual`, `message_in_room`, `http_results`, …) and can emit `message.post`. There is a reserved `derrick.ui.WebhookService` identity, but it is only a name: no listener, no DB, no UI.

There is no `AgentEvent` type in this repo. The closest pieces are `PluginHopEvent` (plugin stdin) and `AgentTurnRequest` (chat turns). Messaging should not reuse chat turns.

## Why a Docker webhook is a bad fit

Guest containers run `--network none`. They cannot sit on a port. Secrets never enter the guest. Slack Events and Telegram webhooks need a **public HTTPS URL** pointing at this Mac. That means port-forwarding, a tunnel, and a new attack surface, all for something the user should never have to set up.

Slack Socket Mode and Telegram `getUpdates` are **outbound**. The Mac opens a connection, then events arrive. That matches Keychain secrets, Host HTTP, and the existing XPC mesh.

Use Docker only to **translate** a vendor payload with the connector plugin. Use a Swift service to **listen**.

## Recommended split

**Host (Swift, always on with derrickd)**
Long-lived ingress per connected plugin. Slack: Socket Mode (or poll if needed). Telegram: long poll. Persist messages. Tell the UI “new message in this thread.” Sending goes the same way as today: invoke the plugin, host does HTTP, attach Keychain secrets.

**Guest (existing plugin container)**
Stateless. On receive: host gives it a `message_in_room` (or a new `message_inbound`) event. Plugin maps vendor JSON → a Derrick message. On send: UI text → plugin → `http.request` → `message.post`. No listen loop in Docker.

That is the WebhookService slot, but name the product **Messaging** and the process **ingress**, not webhook. Optional public webhooks can wait.

## UI: Messaging is not Chat

A third sidebar mode is right: Recents / Plugins / **Messaging**.

Under Messaging, one row per **connector plugin** (not every plugin). Mark connectors in `plugin.json` (`extensions.app.derrick.role: "connector"` or `secrets` + a connector profile). Do not guess from the name.

Each connector opens **thread tabs**, like chat tabs, but a different session kind. Job sessions were already kept out of chat; do the same here. Key: `pluginID + vendorThreadID` (Slack channel/DM/thread, Telegram chat id).

Clicking a vendor row opens that connector and **auto-opens the most recent conversation**. Unread badges on the vendor row and on conversation tabs.

No `/connect-slack` in chat. Opening Messaging for that connector **is** the mode. Still needed: credentials (already exist), a connected/listening switch, a channel list the first time, and per-conversation mute.

## Database

Do not stuff this into chat sessions.

Something like:

- `messaging_connectors` — plugin id, display name, listen state
- `messaging_threads` — connector, vendor thread id, title, last activity, muted, unread count
- `messaging_messages` — thread, direction in/out, sender, body, vendor ids, time

Idempotent insert by vendor message id inside one `BEGIN IMMEDIATE` transaction. Thread upsert never overwrites mute or unread. Unread bumps only when a new inbound row lands on an unmuted thread. Page older messages with a `(created_at, id)` cursor.

## Send vs receive vs agent

Receive and archive should **not** start an Agent turn. That would burn tokens on every Slack ping.

Chat remains “talk to Derrick.” Messaging is “talk to people through a connector.” Later you can add “ask Derrick about this thread” as an explicit action.

## Inbound UX (locked)

Save first, then notify. No agent turn.

1. Ingress gets the vendor payload. Connector plugin translates it. Host writes SQLite (idempotent on vendor message id) and updates thread last-activity.
2. UI reports the current route to the daemon (`messaging workspace` + vendor + thread). Daemon is still the sole banner poster. Being in Chats with a leftover selected thread does **not** count as viewing.
3. **OS banner** unless:
   - the user is already on that exact conversation (even if scrolled up), or
   - the conversation is muted, or
   - the message is outbound from this Mac.
4. If they are in that conversation but scrolled up: skip the OS banner; show an in-thread “new messages” pill. Do not yank scroll. If they are at the bottom, append.
5. Bursts: save every row; **one banner per thread** in a short window (“3 new messages in #general”), not one banner per message.
6. Banner tap: wake the **main window** (not a job-result panel) and jump to **that conversation**.
7. Vendor row click: open that connector and auto-open the most recent conversation.
8. Thread list still exists under the vendor (badges, mute, pick another channel). Do not load every channel’s messages at once.

### Conversation view

Chat style: newest at the **bottom**. Open scrolled to the bottom. Scroll **up** for older.

Sliding window of **100 messages per open tab**. Older rows stay in SQLite; they only leave the screen. Anchor scroll when paging so the message you were reading stays put. Jump-to-latest returns to the newest 100.

Unread badges on the vendor row and on conversation tabs. Mute is per conversation.

## Order to build

1. Connector mark in the manifest + Messaging sidebar + empty thread tabs — **in code**
2. DB archive + load history — **in code** (live ingress not yet)
3. Send from a thread (plugin invoke + Keychain HTTP)
4. Swift ingress (Telegram poll is simpler than Slack Socket Mode)
5. Live UI updates when a message lands

Skip inbound Docker ports, skip mixing threads with chat sessions, skip treating every plugin as a connector.

A plugin appears under Messaging only when `extensions.app.derrick.role` is `"connector"`. Rebuild older connectors so the factory writes that field.
