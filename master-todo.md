# Derrick master todo

Living list. Newest decisions first. Check items off in the same change that lands them.

## Now

### Messaging tabs vs Slack reply threads (locked)

- **Conversations** (Slack channels/DMs the bot is in) are **tabs**. Show every discovered conversation. Only the selected tab loads the 100-message window.
- **Slack reply threads are not tabs.** They nest under a channel as a child pane (`#general › thread`).
- New connectors from the wizard are **full sync**: channel history plus reply threads (`conversations.replies` / `thread_ts`). The current send+receive Slack connector does not fetch replies — recreate it after this change.

- [x] Open all connector conversations as tabs (not only the most recent, and not a picker when two or more exist).
- [x] Switch wizard/default connector scope to full sync with nested reply-thread UI.

### News reader plugins (not built yet)

Wizard type is already on the create form (disabled). Unlock it with a **preset wizard**, not an open-ended “describe your news plugin” box. Same rule as connectors: structured choices the host can run and show.

**Wizard (after type = News reader):**

1. **Topic** — pick from a list (financial, tech, international, politics, …) or type a custom topic.
2. **Source** — pick from a list of outlets, or paste a news-source URL.
3. **Mode** — **List articles** or **Summaries** (one topic, several sources).
4. **Max count** — cap how many items come back.
5. **Schedule (optional)** — run this plugin on a timer (same host job/schedule path as other Derrick work). Off by default. If set, Derrick fetches the list or summaries at that interval and presents them; if unset, it only runs when asked.

**Product rules:**

- Every list item **always** includes the source link. No headline-only rows.
- Presets + custom topic + custom URL is the flexibility. Do not add a free-text feature dump.
- Do not turn outlet docs into an API/capability checklist. Docs (if any) stay a factory crawl.
- Later extras need a Derrick surface first (a news list/summary UI the host can present). No toggle until that exists.

**Doability (keep the factory small):**

- Host ops stay few and testable: fetch items for topic+source(s), return `{title, source_url, …}` up to max count; summaries are the same items plus a short digest, still with links.
- List mode can be one outlet (or one URL). Summary mode uses multiple sources on the chosen topic.
- Custom URL is a start page / feed the crawler or Host HTTP can fetch. Reject “scrape the whole web.”
- Custom topic is a search/filter string, not a new plugin kind.
- Schedule is optional and uses existing JobService delay/repeat — do not invent a second scheduler. Unscheduled plugins stay on-demand.

- [ ] Enable News reader in the create wizard; keep Custom disabled.
- [ ] Structured input (topic, source(s), mode, max count, optional schedule) → factory goal. No `User requirements:` free text.
- [ ] Always emit source links on every item. Enforce in validation, not only in the prompt.
- [ ] Host UI that can show a linked list (and summaries) before shipping extras.
- [ ] Optional schedule: persist with the plugin, run via JobService, still show source links on every item.

### File paths: read vs convert

- [ ] **Read:** send attached files (and images) to the model as native multimodal input. Do not run `files.extract` just so the model can see a PDF/md/csv.
- [ ] **Convert:** keep the file-extractor Docker product. Use it only when the user wants a real output file (csv↔xlsx, pdf/docx/html→markdown, etc.).
- [ ] Stop prompting the agent to call `files.extract` for ordinary reads (`mcp_tool_instructions`, `files_extract_skill`, attachment composer).
- [ ] LLM client today is text-only (OpenAI `content: String`, Gemini `GeminiPart(text:)`). Needs image/PDF/file parts.

### Attachment and export lifetime

After a **successful convert**:

1. Present the result to the user if they asked for a real file (save/reveal/chat download). For text outputs, the tool result preview is enough for the model.
2. Delete that job’s files under `file-exports/<job-id>/`.
3. Delete **only the originals that job used** from `chat-attachments/<session>/`. Do not wipe other chats or unused attachments.
4. If convert fails, keep originals so they can retry.

Scratch `file-jobs/<uuid>/` already goes away when the container exits. Keep that.

Do **not** delete attachments after a read-only turn. The user may still convert later in the same chat.

Open: binary convert (xlsx) has no “here is your file” UI yet. Do not delete an export until that handoff exists, or convert-to-Excel is a no-op.

### Guest containers: recreate on handoff (decided)

**Decision:** Recreate the container every run. Keep the image cached (`inspect`, pull/build only if missing). Do not reuse a box after it ran code. No idle warm pool.

Each `script_exec` / `plugin.invoke`:

1. Wait for the offline queue (max 1).
2. `docker create` a unique `derrick-guest-runtime-<uuid>` from `python:3.14.7`.
3. Run until the host hop loop is done (terminal envelope, error, or in-use lease TTL).
4. `docker rm -f` immediately — that is “I’m done.”
5. Release the queue slot so the next script can create at once.

Crawler and file extractor stay **oneshot on their own images** and **own queues** (same `DerrickDockerRunQueue` + `OneshotDockerContainer` as guest). Caps: crawl 2, extract 1, guest 1. A crawl can run while a script waits, and the other way around.

- [x] Lock policy: `warmStandbyCount = 0`, `destroyAfterEveryRun`, `neverReusePostExecution`.
- [x] Shared queue + oneshot cleanup; per-kind caps (guest 1, crawler 2, extractor 1).
- [x] Skip image pull when inspect succeeds.

In-use lease TTL (default 7 minutes) stays as the anti-hoard cap. No idle TTL (no warm boxes).

### Docs

- [ ] Sweep `docs/`: drop or mark stale ADRs, fix Python-vs-Swift guest, file extractor vs native reads, container recreate-on-handoff, messaging roadmap items that already shipped.
- [ ] Files to revisit: `docs/adr-swift-script-runtime.md`, `docs/development.md`, `docs/messaging-design.md` remaining table, `docs/opensource-plan.md`, `readme.md` if it still implies one-shot containers only.

### Startup: crawler image build blocks the app

Seen 2026-09-06: **Initialization Failed** — `Docker image build failed for derrick-web-crawler:swift-6.4-v1`. Log starts at Docker buildkit (`#0 building with "default" instance…`) while pulling `swiftlang/swift:nightly-6.4.x-noble` and transferring **~389MB** build context (repo root).

- [x] First launch must not fail the whole UI if crawler image is still building or build fails. Chat should start; crawl can degrade until the image exists.
- [x] Shrink crawler Docker context (build `packages/` only: WebCrawler, Selenops, Structure).
- [x] Surface a short, human error (disk, Docker not ready, timeout), not a raw buildkit dump in the modal.
- [x] Do not block launch on the crawler image. Start the build in the background. If a crawl arrives during that build, wait on the same task (no second `docker build`).

### UI / product (from `todo.rtf`)

- [ ] Content side panel: todo or table of contents for long discussions.

## Done recently (do not re-open without cause)

- Connector create wizard is vendor → Create. No open-ended “describe features.” Factory goal is the fixed send+receive sentence. Do not add a vendor-docs API picker until there is a host surface for each option.
- Guest Swift scripts removed. `script_exec` is Python-only. Leftover `derrick-swift-runtime-*` still swept on daemon Docker init.
- Convert/extract still uses compiled Swift in `derrick-file-extractor`, not guest Swift.
- Connector inbound can notify when the UI is closed.
