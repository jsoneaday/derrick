# Security

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security bugs.

Email the maintainers privately with:

- Description of the issue
- Steps to reproduce
- Impact assessment
- Suggested fix (if any)

We will acknowledge receipt and work on a fix before public disclosure when possible.

## Threat model (summary)

Derrick runs LLM agents with tools on the user's Mac. The design assumes:

- **Untrusted model output** — tools and scripts are gated before execution.
- **Untrusted guest code** — Swift plugins/scripts run in Docker with no network; the host performs HTTP.
- **Untrusted remote content** — fetched HTML and tool output are sanitized before display.
- **Secrets stay on the host** — API keys and connector tokens live in Keychain or local `.env` (dev only); they are not injected into guest containers.

## Security controls

| Layer | Mechanism |
|-------|-----------|
| Script execution | Docker `--network none`, static Swift verifier, LLM script reviewer |
| Network egress | Host HTTP client, egress blacklist, user approval for new destinations |
| Plugins | Factory build + review; hop-limited `http.request`; Keychain-attached auth |
| Inter-process | Code-signed XPC peers, HMAC-signed service messages (release: Keychain secret) |
| Human in the loop | Tool approval, network access prompts, policy modals |
| Policy | Content and usage limits on agent turns |

## Developer secrets

- Never commit `.env`, keys, or databases from `~/Library`.
- Use `git config core.hooksPath .githooks` and `./scripts/verify-no-secrets.sh --history` before publishing.
- Rotate any credential that was ever committed, even if history was rewritten.
