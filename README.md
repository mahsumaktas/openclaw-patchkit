# OpenClaw Patchkit

Stability-first bug-fix patches for [OpenClaw](https://github.com/openclaw/openclaw). 93 curated patches from 4,300+ open PRs, scored with [Treliq](https://github.com/mahsumaktas/treliq) + Sonnet 4.6. Every patch solves a real, observed problem. Nothing speculative, nothing cosmetic.

> **"If it ain't broke, don't fix it."** Working system > theoretically better system.

## Current State

| Metric | Value |
|--------|-------|
| Base version | **v2026.2.24** |
| Active PR patches | **93** (85 open PRs + 8 issue-based) |
| FIX scripts | **3** (environment-specific) |
| Manual patch scripts | 36 (32 PR + 3 FIX + 1 cognitive memory) |
| Cognitive Memory | **v3** (entity extraction, enforced RAG) |
| Waves | 12 |
| Build status | All applied, build OK |
| Last audit | 2026-02-26 (stability audit: 8 removed, 1 split) |

---

## Philosophy

Every change must answer 5 questions before it touches the codebase:

1. Does this solve a **real, observed** problem?
2. Can I **test it in isolation** before applying?
3. Is it **reversible** if something goes wrong?
4. What's the **blast radius** if it fails?
5. What happens if I **don't** make this change?

If any answer is "no" or "unknown" -- skip it, document why.

**Red lines:**
- No touching working subsystems for "improvement"
- No bundled changes -- one PR, one problem
- No changes without a rollback plan
- Verify before assuming

**Stability audit (2026-02-26):** Removed 4 custom expansions (redundant with individual PRs), 3 low-value PRs, split 1 bundled PR. Every removal archived with rationale.

---

## Quick Start

```bash
# Clone
git clone https://github.com/mahsumaktas/openclaw-patchkit.git

# Full pipeline (rebuild + dist patches + extensions + verify)
sudo bash patch-openclaw.sh

# Individual phases
sudo bash patch-openclaw.sh --phase 1    # Source rebuild only
sudo bash patch-openclaw.sh --phase 2    # Dist patches only
sudo bash patch-openclaw.sh --phase 3    # Extension patches only
sudo bash patch-openclaw.sh --status     # Show last run report
sudo bash patch-openclaw.sh --dry-run    # Preview without changes
```

---

## Unified Patch Pipeline

`patch-openclaw.sh` orchestrates all patching in 4 phases:

```
Phase 1: Source Rebuild    -> 93 PR diffs + 3 FIX scripts applied, TypeScript build, dist swap
Phase 2: Dist Patches      -> TLS probe, self-signed cert, LanceDB deps, Cognitive Memory
Phase 3: Extension Patches -> Cognitive Memory (fallback if Phase 2 handled it)
Phase 4: Verification      -> 6 automated checks (entry.js, TLS, cert, memory, LanceDB, version)
```

### 5-Strategy Cascade (Phase 1)

Each PR diff is tried with increasingly relaxed strategies until one succeeds:

| # | Strategy | Description |
|---|----------|-------------|
| 0 | Manual patch | Custom bash/python3 scripts (highest priority) |
| 1 | Clean apply | `git apply` -- exact match |
| 2 | Exclude tests | `--exclude '*.test.*'` |
| 3 | Exclude changelog+tests | `--exclude 'CHANGELOG.md'` + tests |
| 4 | 3-way merge | `git apply --3way` |

Manual patches take priority to ensure reliable application of complex, multi-file changes.

---

## FIX Scripts (3)

Environment-specific fixes for macOS gateway setups. Not upstream PRs, but solve real observed problems:

| Script | Description |
|--------|-------------|
| **FIX-A1** | Pass `tlsFingerprint` to `probeGateway` for self-signed cert probe |
| **FIX-A2** | Catch `ResilientGatewayPlugin` uncaught exception on `maxAttempts=0` (dual-layer: source + carbon node_modules) |
| **FIX-A3** | Accept self-signed cert for wss:// connections without fingerprint |

---

## PR Patches (93)

Organized in 12 waves. Each wave represents a scan/review cycle.

### Wave 1: Hand-picked Critical Fixes (7)
Model allowlist, agent routing, PID cleanup, session contention, Discord delivery, console timestamps, ACP delta flush.

### Wave 2: Systematic Scan (8)
Config safety, compaction repair, prompt injection prevention, session crash guards, surrogate pair truncation, zero-width Unicode bypass.

### Wave 3: Comprehensive Treliq Scan (16)
2,250 PRs scored. Security (prototype pollution, auth header leaks, cron permissions), stability (fetch timeouts, error handling), memory/session (flush fix, BM25 scoring), gateway/channel (Discord v2, SSE encoding, WebSocket 429).

### Wave 4: Sonnet 4.6 Full Scan (14)
4,051 PRs re-scored. Billing failover, Telegram provider IDs, type array handling, auth rate limiting, LaunchAgent CA certs, pairing recovery hints, config env var preservation, FD exhaustion prevention, usage cost totals, error payload filtering, auto-reply guards, logger binding, Telegram reaction filtering.

### Wave 5: Tier 1 Batch (3)
Score >= 80. TLS exposure warning, hook session context, cron delivery mode.

### Wave 6: Deep Review Batch (9)
Daemon stop fix, echo loop prevention, hook agentId enforcement, session corruption prevention, orphan tool results, cron write drain, BM25 minScore cap, child run finalization, heartbeat transcript preservation.

### Wave 7: High-Risk Manual Patches (3)
- **#24840a**: env.vars redaction with `register(sensitive)` (split from bundled PR)
- **#24840c**: CLI `--url` to `--cookie-url` rename (split from bundled PR)
- **#25381**: Preserve thinking blocks during compaction (selective: 3 files from 12-file PR)

### Wave 8: Nightly Scan Batch (10)
First automated batch. Pre-auth WS handshake cap, pre-auth frame limit, group chat allowlist, KeepAlive plist fix, graceful drain, OpenAI ingress bind, streaming fetch errors, cron jobId normalization, double compaction guard, Discord resume death spiral.

### Wave 9: Targeted Fixes (6)
Undici TLS crash-loop, stale PID kill, post-compaction token clearing, media serve allowlist, EXTERNAL_UNTRUSTED_CONTENT leak stripping, typing keepalive failsafe.

### Wave 10: Analysis Report Batch (6)
Secret detection, network config overrides, typing keepalive race prevention, allowAgents schema, cross-provider thinking block strip, lone surrogate repair.

### Wave 11: Critical Fixes + Security Hardening (8)
Telegram 401 typing crash, LaunchAgent post-update restart, log rotation, /healthz JSON, spoofed system message neutralization, compaction contextTokens cap, delivery retry cleanup, config unknown key stripping.

### Wave 12: Stability Fixes (4)
Typing indicator leak (4-channel onCleanup), Discord reconnect crash, TLS probe fingerprint, WSS self-signed cert fallback.

---

## Cognitive Memory v3

Research-backed enhancement to OpenClaw's `memory-lancedb` plugin. Entity extraction, enforced RAG, and hybrid capture pipeline on top of the proven cognitive scoring foundation.

### Key Features

| Feature | Description |
|---------|-------------|
| **Entity Extraction** | Regex NER: person, tech, org, project, location. Turkish + English. <5ms. |
| **Enforced RAG** | Memory injection on every prompt. Threshold 0.75, top-K 3, entity boost +0.1/overlap. |
| **Hybrid Capture** | Heuristic score >= 0.5 direct, 0.2-0.5 LLM verify (gpt-4o-mini), < 0.2 skip. |
| **Activation Scoring** | `similarity (50%) + recency*frequency (35%) + importance (15%)` (ACT-R model). |
| **Confidence Gating** | Returns nothing when best match < threshold. Prevents noise injection. |
| **Semantic Dedup** | Merges near-duplicates (0.85 threshold). Content hash dedup for exact matches. |

### Schema (16 fields)

```
id, text, vector, importance, category, createdAt, accessCount, lastAccessed,
stability, state, contentHash, relatedTo, entities, sourceAgent, captureScore, llmVerified
```

Auto-migration from v1 and v2 schemas. Research: [`research/`](research/).

---

## Automation

### Nightly Scan (`nightly-scan.sh`)

Runs daily at 5 AM via cron:
1. Fetches up to 500 recently-updated PRs
2. Scores with Treliq + Sonnet 4.6
3. Runs `git apply --check` on high-score PRs
4. Checks if patched PRs have been merged/closed upstream
5. Reports to Discord with apply status tags

### Post-Update Check (`post-update-check.sh`)

LaunchAgent triggered by `package.json` changes:
- Detects version changes via marker file
- Runs full `patch-openclaw.sh` pipeline
- Restarts gateway after successful patching

### Health Monitor (`health-monitor.sh`)

Checks gateway process, port, Discord/Telegram connections, delivery queue, error logs.

---

## Removed Items (Stability Audit 2026-02-26)

The following were removed during the stability-first audit. All archived in `manual-patches/removed-stability-audit/`:

| Item | Reason |
|------|--------|
| **EXP-1** (Webhook Deduplicator) | Grammy already handles `update_id` dedup. False positive risk. |
| **EXP-2** (Gateway Firewall) | Redundant with PRs #25966, #25973, #25093. |
| **EXP-3** (Lifecycle Manager) | Redundant with PRs #26626, #26441, #27013. 500 lines on startup path. |
| **EXP-4** (Resilient Connection) | Dead code. No channel uses it. YAGNI. |
| **#24517** (Workspace Locking) | Feature not bugfix. Core pi-tools path risk. Never applied. |
| **#24164** | Cosmetic label change. Zero functional impact. |
| **#11160** | Audio MIME mappings unused. Trivial impact. |
| **#24840-B** (Network Failover) | New logic in errors.ts hot path. Risky. A + C retained as separate scripts. |

---

## Bug Fixes Applied Beyond PRs

### Typing Failsafe Timer Fix (2026-02-26)

**Problem:** PR #27021's failsafe timer (120s) was re-armed on every `onReplyStart()` call. `createTypingController`'s 6s `typingLoop` calls `onReplyStart()` every tick, resetting the 120s timer endlessly. The failsafe never fires.

**Fix:** `if (failsafeTimer) return;` instead of `clearTimeout(failsafeTimer)` in `armFailsafe()`. Don't re-arm if already armed. `fireStop()` clears the timer, so next fresh start re-arms correctly.

Applied to both dist JS and manual patch script.

---

## Files

```
openclaw-patchkit/
|-- README.md
|-- LICENSE                              # MIT
|-- pr-patches.conf                      # 93 PR patches + 3 FIX (single source of truth)
|-- patch-openclaw.sh                    # Unified 4-phase orchestrator
|-- rebuild-with-patches.sh              # Phase 1: source rebuild (5-strategy cascade)
|-- dist-patches.sh                      # Phase 2: compiled JS patches + cognitive memory
|-- post-update-check.sh                 # Auto-patch after OpenClaw updates
|-- discover-patches.sh                  # Scan GitHub for new PRs
|-- nightly-scan.sh                      # Automated nightly scan + scoring + Discord reports
|-- health-monitor.sh                    # Gateway health checker
|-- notify.sh                            # Discord notification helper
|-- install-sudoers.sh                   # Passwordless sudo for patch scripts
|-- cognitive-memory-patch.sh            # Standalone cognitive memory installer
|-- scan-registry.json                   # 4,300+ scored PRs with metadata
|-- manual-patches/                      # 36 active scripts
|   |-- <PR_NUM>-<name>.sh              # 32 PR-based manual patches
|   |-- FIX-A{1,2,3}-*.sh              # 3 environment-specific fixes
|   |-- cognitive-memory-patch.sh        # Cognitive memory v3 extension
|   +-- removed-stability-audit/         # 7 archived scripts (audit 2026-02-26)
|-- cognitive-memory-backup/             # Patched + original memory extension files
|-- docs/
|   |-- cognitive-memory-specs.md        # Implementation specs
|   +-- analysis/                        # Deep analysis reports
+-- research/
    |-- scientific-validation.md          # Peer-reviewed evidence
    +-- msam-analysis.md                  # MSAM deep dive
```

## Upgrade Policy

- **Stay on current base** until PR merges reduce patch count or a critical security fix lands
- **v2026.2.25 skipped**: 0 PRs merged, 2 conflicts, TS 7.0.0-dev risk
- PR close != removal: closed PRs stay if the fix is still valuable
- Manual patches are idempotent (safe to re-run)
- `pr-patches.conf` is the single source of truth
- `patch-openclaw.sh --status` shows last pipeline results

## Disclaimer

This repository contains only tooling scripts, patch metadata, research documents, and build automation. It does **not** include OpenClaw source code or patched binaries.

[OpenClaw](https://github.com/openclaw/openclaw) is developed by its maintainers. Patches reference open PRs submitted by various contributors.

## License

[MIT](LICENSE)
