# Agent Self-Improvement Loop

> A reference implementation of a **self-healing, self-improving AI agent** — from signal gathering through LLM-driven drafting, isolated smoke-testing, and gated (or autonomous) merge. MIT-licensed, by [Crowork](https://crowork.ai).

---

## The Problem

AI agents accumulate bugs, miss edge cases, and fall behind the open-source projects they build on. Manual code review does not scale. What if the agent could fix itself — safely?

The pattern: **learn from your own failures → draft a fix → prove it works in isolation → merge only when it's safe**. No TODO comments. No future phases. Close the loop now.

---

## The Loop

```
┌─────────────────────────────────────────────────────────────────┐
│                   SELF-IMPROVEMENT LOOP                         │
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │  1. GATHER   │───▶│  2. REVIEW   │───▶│   3. DRAFT       │  │
│  │  SIGNALS     │    │  (LLM gate)  │    │  (LLM in         │  │
│  │              │    │              │    │   worktree)       │  │
│  │ - error logs │    │ Is this idea │    │                  │  │
│  │ - upstream   │    │ applicable   │    │ Writes change.diff│  │
│  │   OSS commits│    │ to OUR stack?│    │ + PROPOSAL.md    │  │
│  │ - runtime    │    │              │    │ Never touches     │  │
│  │   anomalies  │    │ applicable   │    │ live code         │  │
│  └──────────────┘    │ items →      │    └────────┬─────────┘  │
│                      └──────────────┘             │            │
│                                                   ▼            │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │  6. MEMORY   │◀───│  5. GATED    │◀───│   4. SMOKE TEST  │  │
│  │  CONSOLIDATE │    │  APPLY       │    │  (in worktree)   │  │
│  │              │    │              │    │                  │  │
│  │ Dedup+merge  │    │ Human gate:  │    │ Real build tool  │  │
│  │ Never drop   │    │  /approve_si │    │ NOT tsc --noEmit │  │
│  │ critical     │    │ OR           │    │                  │  │
│  │ entries      │    │ Autonomous:  │    │ PASS → proposal  │  │
│  │              │    │  guardian-   │    │ FAIL → discard   │  │
│  │ Anomaly scan │    │  protected   │    │                  │  │
│  │ before merge │    │  auto-merge  │    │                  │  │
│  └──────────────┘    └──────────────┘    └──────────────────┘  │
│                             │                                   │
│                    ┌────────┴─────────┐                         │
│                    │  GUARDIAN PAIR   │                         │
│                    │                  │                         │
│                    │ memory-guardian: │                         │
│                    │  snapshot before │                         │
│                    │  restore if lost │                         │
│                    │                  │                         │
│                    │ relay-guardian:  │                         │
│                    │  record SHA      │                         │
│                    │  git reset --hard│                         │
│                    │  if service dies │                         │
│                    └──────────────────┘                         │
└─────────────────────────────────────────────────────────────────┘
```

### Why each stage matters

| Stage | What it does | Why it can't be skipped |
|-------|-------------|------------------------|
| **Gather** | Pulls error logs, upstream OSS commits, runtime anomalies into a queue | Without signals the loop has nothing to improve from |
| **Review** | LLM judges each signal: is the idea genuinely applicable to THIS agent's stack? | Prevents blindly applying unrelated patches |
| **Draft** | LLM writes the minimal code change inside an isolated `git worktree` | Live code is never touched during drafting — a crashed draft cannot break production |
| **Smoke test** | Runs the real build tool (e.g. `bun build`) inside the same worktree | `tsc --noEmit` does not resolve imports; only the real build catches missing modules |
| **Gated apply** | Applies the diff to live code, re-smoke-tests, commits and redeploys | Human gate (default) or guardian-protected autonomous gate — never raw auto-merge |
| **Memory consolidate** | Merges/deduplicates the agent's observation log; never drops critical entries | Without consolidation the memory grows unbounded; without the guard it loses critical facts |

---

## Why "learn from your own bugs"?

Most self-improvement loops only harvest from upstream OSS. This one also ingests **the agent's own error log**. A failed cron run, an unhandled exception, a smoke-test rejection — all become signals. The agent that broke itself is the one that fixes itself.

---

## Key Design Decisions

### 1. Worktree isolation
Drafting happens in a `git worktree` — a detached copy of the repo at a temporary path. The LLM edits files there. If it crashes, panics, or produces garbage, `git worktree remove` cleans up. Live code is untouched.

### 2. Real smoke test, not type-check
```bash
# RIGHT: resolves all imports, catches missing modules
bun build src/main.ts --target=bun --outfile=/dev/null

# WRONG: only checks syntax in the files it finds, misses runtime wiring
npx tsc --noEmit
```
The test that actually runs in production is the build tool. Use that.

### 3. Guardian pair (autonomous mode)
When running without a human gate, two mechanical guardians protect the two invariants that must never break:

- **memory-guardian**: snapshots all memory stores before merge, checks integrity after, restores from snapshot on any corruption or loss.
- **relay-guardian**: records the pre-merge git SHA, health-checks the service for N seconds post-restart, `git reset --hard` back to the known-good SHA if the service dies.

A bad merge is caught and rolled back **automatically**, with no human needed overnight.

### 4. Diff path restriction
`git apply --include='src/*'` — the diff can only touch source files. Package manifests, config files, workflow definitions, and secrets are unreachable by design, even if a malformed or adversarial diff tries to touch them.

### 5. Memory consolidation never drops critical entries
The consolidation prompt explicitly counts `🔴` (critical) observations before and after. A second-pass verifier (smaller model) checks the count and rejects the consolidation if any critical entry is missing. An aggressive consolidation (>80% reduction) is also rejected.

---

## Quick Start

### Prerequisites
- [Bun](https://bun.sh) >= 1.0 (or Node 20+ with minor adaptation)
- An LLM with an API (configured via env vars — see `.env.example`)
- A git repo you want the agent to improve

### Setup

```bash
git clone https://github.com/muninnravenbot-ux/agent-self-improvement
cd agent-self-improvement
cp .env.example .env
# Edit .env: set REPO_PATH, LLM_API_KEY, BUILD_CMD, etc.
bun install  # no dependencies currently — future plugins go here
```

### Run a dry-run of the full loop

```bash
DRY_RUN=1 bash src/self-improve.sh
```

This gathers signals, reviews them, drafts proposals, smoke-tests each one, but **never commits or restarts anything**.

### Run with human gate (default)

```bash
bash src/self-improve.sh
# Proposals appear in $STAGING_DIR/<id>/PROPOSAL.md
# Approve one:
bash src/apply-change.sh <proposal-id>
```

### Run in autonomous mode (guardian-protected)

```bash
AUTONOMOUS=1 bash src/self-improve.sh
# Merges automatically. Guardians roll back on failure.
# Memory and service invariants enforced mechanically.
```

---

## Configuration

Copy `.env.example` to `.env`:

```bash
# Path to the repo the agent should improve
REPO_PATH=/path/to/your/repo

# Build command that proves the code compiles + resolves correctly
# Use your real build tool — not a type-checker
BUILD_CMD="bun build src/main.ts --target=bun --outfile=/dev/null"

# LLM API for drafting (any OpenAI-compatible endpoint)
LLM_API_BASE=https://api.openai.com/v1
LLM_API_KEY=sk-...
DRAFT_MODEL=gpt-4o

# LLM for review (can be a smaller/cheaper model)
REVIEW_MODEL=gpt-4o-mini

# LLM for memory consolidation
CONSOLIDATE_MODEL=gpt-4o-mini
VERIFY_MODEL=gpt-4o-mini

# Staging area for proposals (outside the repo)
STAGING_DIR=/tmp/agent-si-staging

# Upstream repos to watch for improvements (comma-separated owner/repo)
WATCH_REPOS=open-source-org/project-a,open-source-org/project-b

# Service restart command (adapt to your process manager)
RESTART_CMD="systemctl --user restart myagent.service"

# Health check: how many seconds the service must stay up post-restart
HEALTH_WINDOW=20

# Notification command (optional — leave blank to disable)
# Must accept one string argument (the message)
NOTIFY_CMD=""

# Max proposals to draft per run
MAX_PER_RUN=2

# Autonomous mode: 1 = guardian-protected auto-merge, 0 = human gate required
AUTONOMOUS=0

# Dry run: 1 = apply+smoke+rollback only, never commit/restart/notify
DRY_RUN=0
```

---

## File Structure

```
agent-self-improvement/
├── src/
│   ├── self-improve.sh          # Orchestrates the full pipeline (entry point)
│   ├── gather-signals.sh        # Stage 1: error logs + upstream commits → signals.jsonl
│   ├── review-gate.sh           # Stage 2: LLM applicability gate → applicable.jsonl
│   ├── draft-change.sh          # Stage 3: LLM drafts in isolated worktree → PROPOSAL.md
│   ├── smoke-test.sh            # Stage 4: real build gate (called from draft + apply)
│   ├── apply-change.sh          # Stage 5: human-gated or guardian-protected merge
│   ├── consolidate-memory.sh    # Stage 6: memory dedup with critical-entry guard
│   └── lib/
│       ├── memory-guardian.sh   # Snapshot + restore memory stores
│       ├── relay-guardian.sh    # Health-check + auto-rollback service
│       └── llm.sh               # Thin wrapper: POST to LLM_API_BASE
├── examples/
│   ├── minimal-setup.sh         # Bare-bones walkthrough of one loop run
│   ├── example-signals.jsonl    # Sample signal queue to feed the review gate
│   └── README.md                # How to run the example
├── .env.example
├── package.json
├── LICENSE
└── README.md
```

---

## Extending

**Different LLM**: change `LLM_API_BASE` and model env vars. The `lib/llm.sh` wrapper speaks the OpenAI Chat Completions format — any compatible API works.

**Different build tool**: change `BUILD_CMD`. The smoke test is just a shell command that returns 0 on success.

**Different signal sources**: add a gatherer in `gather-signals.sh`. The queue format is newline-delimited JSON: `{"source":"...", "sha":"...", "message":"...", "repo":"..."}`.

**Different memory format**: the consolidator works on plain-text observation files. Adapt the prompt and the `🔴/🟡/🟢` priority markers to whatever format your agent uses.

---

## Prior Art / Inspiration

This pattern is informed by production experience running always-on AI agents. The core insight: **a test suite that never runs in production is a false guarantee**. The build tool that will run the code in production is the only honest smoke test.

---

## Contributing

Issues and PRs welcome. The goal is a small, readable, auditable toolkit — not a framework. Keep each module under 200 lines.

---

## License

MIT — Copyright (c) 2026 Crowork. See [LICENSE](LICENSE).
