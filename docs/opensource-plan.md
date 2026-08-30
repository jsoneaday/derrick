# Open-source readiness plan

Checklist for publishing Derrick as a public repository. **Status: complete** (2026-08-30).

## Phase 0 — Secret audit

- [x] `.env` in `.gitignore`; never committed
- [x] `scripts/verify-no-secrets.sh` (`--staged`, `--history`)
- [x] `.githooks/pre-commit` runs staged scan
- [x] `.env.example` shipped; `ui/ui/Resources/.env` gitignored
- [x] GitHub Actions secret scan job (`.github/workflows/ci.yml`)

## Phase 1 — Remove personal / internal-only content

- [x] Sidebar: neutral “Account / Local” copy
- [x] Empty state: “What can Derrick help with?”
- [x] UI test updated
- [x] Xcode file headers: `Created by` → `Derrick`
- [x] ADRs use `<TEAM_ID>` placeholder in prose
- [x] Debug SQLite path moved to `docs/development.md`
- [x] Removed `.github/agents/Tell.agent.md` (internal Cursor agent)

## Phase 2 — Documentation

- [x] `README.md` — product, architecture, security
- [x] `CONTRIBUTING.md`
- [x] `SECURITY.md`
- [x] `docs/development.md`
- [x] `docs/opensource-plan.md` (this file)
- [x] Existing ADRs retained

## Phase 3 — Repository hygiene

- [x] `LICENSE` Apache 2.0; `THIRD_PARTY_NOTICES.md` for SPM deps (no separate NOTICE required)
- [x] `CODEOWNERS` (update `@your-github-username` before publish)
- [x] Issue templates + PR template (`.github/`)
- [x] CI: secret scan + `xcodebuild` build + package/ui tests
- [x] Xcode 27 / Swift 6.4 pinned in README and CONTRIBUTING
- [x] SPM dependency licenses listed in `THIRD_PARTY_NOTICES.md`
- [x] Legacy XPC docs in `services-plan.md` reflect in-process daemon (verified)
- [x] No analytics keys or internal hostnames in tracked source

## Phase 4 — Build & sign for outsiders

- [x] `Config/Signing.xcconfig.example` + `scripts/configure-signing.sh`
- [x] Login Items / Background App Activity documented in `docs/development.md`
- [x] Docker image documented in README, CONTRIBUTING, ADR
- [x] `scripts/build.sh` wrapper

## Phase 5 — Security story (public-facing)

- [x] README + SECURITY.md cover: Docker sandbox, script reviewer, Swift verifier, egress blacklist, HITL, signed XPC, plugin secrets, policy engine, messaging

## Phase 6 — Legal & community

- [x] Default branch: `main`
- [x] `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1)
- [x] README trademark note
- [x] `THIRD_PARTY_NOTICES.md` (SPM + external APIs)

## Phase 7 — Pre-publish gate

Run before making the repo public:

```bash
git config core.hooksPath .githooks
./scripts/verify-no-secrets.sh --history
./scripts/verify-no-secrets.sh --staged
./scripts/build.sh test
```

Manual smoke test: fresh clone → `.env` → build `ui` → chat → plugin factory → messaging connector.

**Before publish:** update `CODEOWNERS` with your GitHub username.
