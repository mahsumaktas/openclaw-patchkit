# OpenClaw Patchkit

Curated bug-fix patches for [OpenClaw](https://github.com/openclaw/openclaw), selected from 4,300+ open PRs using AI-powered scoring ([Treliq](https://github.com/mahsumaktas/treliq) + Sonnet 4.6). Includes custom **Expansions** (core enhancements), **FIX scripts** (environment-specific fixes), and a research-backed **Cognitive Memory v3** system.

## Current State

| Metric | Value |
|--------|-------|
| Base version | **v2026.2.24** |
| Next upgrade | v2026.2.26+ (v2026.2.25 analyzed, staying on .24) |
| PRs scanned | 4,320+ |
| PRs scored (Sonnet 4.6) | 4,051 |
| PR patches | **94** (86 open PRs + 8 issue-based) |
| FIX scripts | **3** (environment-specific) |
| Expansions | **4** (custom core enhancements) |
| Manual patch scripts | 42 |
| Cognitive Memory | **v3** (entity extraction, enforced RAG, hybrid capture) |
| Waves | 12 |
| Build status | 94 PR + 3 FIX + 4 EXP, all applied, build OK |
| Last updated | 2026-02-26 |

> **v2026.2.25 decision:** Analyzed on release day. 0 of our PRs merged, 2 CONFLICT patches would need rewriting, TypeScript 7.0.0-dev risk. Staying on v2026.2.24 until next release reduces rebase churn. Full analysis in commit history.

---

## Quick Start

```bash
# Clone
git clone https://github.com/mahsumaktas/openclaw-patchkit.git

# Full pipeline (rebuild + dist patches + extensions + verify)
sudo bash patch-openclaw.sh

# Or run individual phases:
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
Phase 1: Source Rebuild    -> 94 PR diffs + 3 FIX scripts + 4 expansions applied, TypeScript build, dist swap
Phase 2: Dist Patches      -> TLS probe, self-signed cert, LanceDB deps, Cognitive Memory
Phase 3: Extension Patches -> Cognitive Memory (fallback if Phase 2 handled it)
Phase 4: Verification      -> 6 automated checks (entry.js, TLS, cert, memory, LanceDB, version)
```

### 5-Strategy Cascade (Phase 1)

Each PR diff is tried with increasingly relaxed strategies until one succeeds:

| Strategy | Description | Count |
|----------|-------------|-------|
| 1. Manual patch | Custom bash/python3 scripts | 34 |
| 2. Clean apply | `git apply` — exact match | 51 |
| 3. Exclude tests | `--exclude '*.test.*'` | 7 |
| 4. Exclude changelog+tests | `--exclude 'CHANGELOG.md'` + tests | 3 |
| 5. 3-way merge | `git apply --3way` | 0 |
| **Total** | | **94 PRs + 3 FIX + 4 expansions** |

Manual patches take priority (Strategy 0) to ensure reliable application of complex, multi-file changes.

---

## Custom Expansions

Beyond cherry-picking PRs, the patchkit includes 4 custom core enhancements that address systemic issues identified across multiple PRs.

### EXP-1: Generic Webhook Deduplicator
**Risk: Low** | **New: `src/channels/webhook-deduplicator.ts` (~160 lines)**

Channel-agnostic middleware for detecting and dropping replayed/duplicate webhook events. Uses bounded LRU cache (8192 entries, 10 min TTL) with per-channel metrics. Integrated into Telegram webhook handler via `update_id` dedup. Future channels (LINE, Slack, Google Chat) can import directly.

*Supersedes: PR #26047 (LINE-specific dedupe)*

### EXP-2: Gateway Pre-Auth Firewall
**Risk: Medium** | **New: `src/gateway/firewall.ts` (~300 lines)**

Centralized pre-authentication security layer with 5 configurable rules:
- IP blocklist
- Pending handshake cap (50 concurrent)
- Per-IP rate limiting (20/min)
- Burst detection (10 connections in 5s)
- Pre-auth frame size limit (64 KiB)

Loopback addresses always exempt. Complements existing `auth-rate-limit.ts` (which handles post-auth) and `unauthorized-flood-guard.ts` (post-connect only).

*Consolidates: PRs #25966, #25973, #25093*

### EXP-3: Graceful Lifecycle Manager
**Risk: High** | **New: `src/gateway/lifecycle-manager.ts` (~400 lines)**

4-phase shutdown orchestration: DRAIN -> FLUSH -> CLEANUP -> EXIT. Includes startup validation (port availability, config file checks), signal handling (SIGTERM/SIGINT), and configurable per-phase timeouts. Opt-in wrapper that doesn't modify existing `server-close.ts` — adds orchestration layer on top.

*Consolidates: PRs #26626, #26441, #25219, #26502*

### EXP-4: Resilient Channel Connection
**Risk: Low** | **New: `src/channels/resilient-connection.ts` (~350 lines)**

Abstract base class for channel connections with:
- Exponential backoff with configurable jitter
- Circuit breaker (closed/open/half-open states)
- Stale session detection and auto-reconnect
- Health check integration
- Event system and metrics

Fully additive — no existing files modified. Discord and IRC can extend this base class to replace their individual reconnect implementations.

*Supersedes: PRs #25974 (Discord death spiral), #26918 (IRC monitor)*

---

## FIX Scripts (3)

Environment-specific fixes that aren't upstream PRs but solve real problems in macOS gateway setups:

| Script | Description |
|--------|-------------|
| **FIX-A1** | Pass `tlsFingerprint` to `probeGateway` for self-signed cert probe |
| **FIX-A2** | Catch `ResilientGatewayPlugin` uncaught exception on `maxAttempts=0` |
| **FIX-A3** | Accept self-signed cert for wss:// connections without fingerprint |

---

## Cognitive Memory v3

A research-backed enhancement to OpenClaw's `memory-lancedb` plugin. v3 adds entity extraction, enforced RAG with entity boost, and a hybrid capture pipeline on top of the proven v2 cognitive scoring foundation.

### v3 Features (NEW)

| Feature | What it does |
|---------|-------------|
| **Entity Extraction** | Regex NER extracts person, tech, org, project, location entities with canonical URIs (`entity://type/slug`). Turkish + English. Zero dependencies, <5ms. |
| **Enforced RAG** | Smart memory injection on every prompt. Threshold 0.75, top-K 3, +0.1 score boost per entity overlap. ~600 tokens/prompt. |
| **Hybrid Capture Pipeline** | 3-layer: heuristic scoring (5 patterns) -> decision logic (>=0.5 direct, 0.2-0.5 uncertain) -> LLM verify (gpt-4o-mini, ~30% of messages). |
| **Agent Tagging** | Every memory tagged with `sourceAgent` (hachiko, scout, analyst, etc). Shared pool, agent-specific display in context. |
| **LLM Verification** | Uncertain captures verified by gpt-4o-mini. Stores `llmVerified` flag and LLM-assigned importance. |

### v2 Foundation (Proven)

| Feature | What it does | Evidence |
|---------|-------------|----------|
| **Activation Scoring** | `similarity (50%) + recency x frequency (35%) + importance (15%)` | ACT-R cognitive model, Park et al. 2023, Mem0 production |
| **Confidence Gating** | Returns nothing when best match < threshold, prevents irrelevant context injection | Self-RAG (Asai et al., ICLR 2024), FLARE (Jiang et al., 2023) |
| **Semantic Dedup** | Merges near-duplicate memories (0.85 threshold), updates text to latest | Standard IR deduplication |
| **Content Hash Dedup** | sha256-based exact dedup before embedding, zero-cost identical rejection | Deterministic, no false positives |
| **Related-To Linking** | Bidirectional links between 0.60-0.84 similarity memories | memU-inspired cross-referencing |
| **Category-based Decay** | `preference/entity = never`, `fact = very slow`, `decision = medium`, `other = fast` | MaRS benchmark (Dec 2025, 300 runs). Batch updates (N+1 fix in v3) |

### Schema (v3 -- 16 fields)

```
id, text, vector, importance, category, createdAt, accessCount, lastAccessed,
stability, state, contentHash, relatedTo, entities, sourceAgent, captureScore, llmVerified
```

Auto-migration from v1 and v2 schemas (probe-based detection).

### Scoring Pipeline

```
Enforced RAG (before_agent_start):
  Query -> Embed -> Extract Entities -> Vector Search (2x candidates, 0.6 threshold)
       -> Entity Boost (+0.1/overlap) -> Filter >= 0.75 -> Top-K 3 -> Inject Context

Capture Pipeline (agent_end):
  User Messages -> Pre-filter -> Extract Entities -> Heuristic Score
       -> Score >= 0.5: Direct Capture
       -> 0.2-0.5: LLM Verify (gpt-4o-mini) -> Capture if approved
       -> < 0.2: Skip
       -> Content Hash Dedup -> Semantic Dedup -> Store with entities + agent tag

Memory Lifecycle:
  active -> fading -> dormant (batch decay, category-based rates)
    |         |
    +----<----+ (recalled = reactivated, stability x 1.2)
```

### Configuration

All options are optional with sensible defaults:

```json
{
  "autoRecall": true,
  "autoCapture": false,
  "enforcedRag": true,
  "ragThreshold": 0.75,
  "ragTopK": 3,
  "captureMode": "hybrid",
  "captureLlmModel": "gpt-4o-mini",
  "similarityWeight": 0.50,
  "activationWeight": 0.35,
  "importanceWeight": 0.15,
  "confidenceThreshold": 0.35,
  "deduplicationThreshold": 0.85
}
```

### CLI Commands

```bash
openclaw ltm stats        # v3 stats: category/state/agent distribution, entities, LLM verified
openclaw ltm search <q>   # Search with entity boost
openclaw ltm decay        # Run batch decay cycle
openclaw ltm revive <id>  # Reactivate dormant memory
```

### Research

Full analysis in [`research/`](research/):

- **[Scientific Validation](research/scientific-validation.md)** -- Evidence review (ACT-R, Self-RAG, MaRS, Ebbinghaus)
- **[MSAM Analysis](research/msam-analysis.md)** -- Multi-Stream Adaptive Memory deep dive
- **[v3 Design](docs/cognitive-memory-specs.md)** -- Implementation specs

---

## PR Patches (94)

Organized in 12 waves, each wave represents a scan/review cycle.

### Wave 1: Hand-picked Critical Fixes (7)
Model allowlist, agent routing, PID cleanup, session contention, security hardening, console timestamps, ACP delta flush.

### Wave 2: Systematic Scan (8)
Config safety, compaction repair, prompt injection prevention, session crash guards, surrogate pair truncation.

### Wave 3: Comprehensive Treliq Scan (18)
2,250 PRs scored with Treliq + Haiku. Categories:
- **Security** (4): prototype pollution, auth header leaks, cron permissions, filename injection
- **Stability** (5): fetch timeouts, heartbeat dedup, error handling, connection classification
- **Memory/Session** (4): flush fix, session store, BM25 scoring, stale model info
- **Gateway/Channel** (5): Discord v2 flags, SSE encoding, oversized messages, WebSocket 429

### Wave 4: Sonnet 4.6 Full Scan (17)
4,051 PRs re-scored with Sonnet 4.6. Categories:
- **Security** (1): auth rate limiting
- **Gateway** (4): LaunchAgent CA certs, pairing requestId, config env var preservation, TLS scheme
- **Stability** (4): billing failover, error payload filtering, FD exhaustion prevention, type arrays
- **Provider/Model** (3): colon provider IDs, codex usage window, audio MIME mappings
- **Channel** (4): Telegram reaction filtering, auto-reply guard, logger binding, archived transcript costs

### Wave 5: Tier 1 Batch (3)
Score >= 80 from curated report. TLS warning, hook context, cron delivery mode.

### Wave 6: Deep Review Batch (9)
Reviewed and approved: daemon stop fix, echo loop prevention, hook agentId enforcement, session corruption prevention, orphan tool result cleanup, cron write drain, BM25 minScore cap, child run finalization, heartbeat transcript preservation.

### Wave 7: High-Risk Manual Patches (3)
Complex multi-file patches requiring custom scripts:
- **#24840**: env.vars redaction + network failover + CLI cookie-url fix
- **#25381**: Preserve thinking blocks in latest assistant during compaction (selective from 12-file PR)
- **#24517**: Shared workspace locking for multi-agent write safety (3 new files)

### Wave 8: Nightly Scan Batch (10)
First batch discovered and applied via automated nightly scanning:
- **Security** (3): pre-auth WS handshake cap, pre-auth frame limit, group chat agent allowlist
- **Gateway** (3): KeepAlive plist fix, graceful drain mode, OpenAI ingress hard-bind
- **Stability** (3): streaming fetch error prevention, cron jobId normalization, double compaction guard
- **Channel** (1): Discord resume death spiral fix

### Wave 9: Targeted Fixes (6)
Undici TLS crash-loop, stale PID kill, post-compaction token clearing, media serve allowlist security, leaked EXTERNAL_UNTRUSTED_CONTENT stripping, typing keepalive failsafe timer.

### Wave 10: Analysis Report Batch (6)
Secret detection in inbound messages, network config overrides, typing keepalive race prevention, allowAgents schema defaults, cross-provider thinking block strip, lone surrogate repair.

### Wave 11: Critical Fixes + Security Hardening (8)
Issue-based patches with manual scripts: Telegram 401 typing crash, LaunchAgent post-update restart, /tmp/openclaw log rotation, /healthz JSON endpoint, spoofed system message neutralization, compaction contextTokens cap, delivery retry queue cleanup, config unknown key stripping.

### Wave 12: Stability Fixes (4)
Typing indicator leak (4-channel onCleanup), Discord reconnect crash (maxAttempts=0), TLS probe fingerprint passthrough, WSS self-signed cert fallback.

### Score Distribution (4,051 PRs)

| Score Range | Count |
|-------------|-------|
| 85+ | 2 |
| 80-84 | 100 |
| 75-79 | 558 |
| 70-74 | 962 |
| <70 | 2,429 |

---

## Automation

### Nightly Scan

`nightly-scan.sh` runs at 5 AM daily via cron:
1. Fetches up to 500 PRs updated in the last 3 days (cursor-based pagination, `sort:updated-desc`)
2. Filters against scan registry -- skips already-scored, re-checks recovered drafts
3. Scores new PRs using Treliq + Sonnet 4.6 (no line-count limit)
4. Runs `git apply --check` on high-score PRs to test patch applicability
5. Checks if patched PRs have been merged/closed upstream
6. Sends results to Discord with apply status tags (`[APPLY OK: strategy]` or `[NEEDS MANUAL]`)
7. Updates `scan-registry.json` and pushes to this repo

### Health Monitor

`health-monitor.sh` checks gateway health:
- Gateway process running
- Port listening
- Discord/Telegram connections active
- Delivery queue status
- Error log analysis

### Post-Update Check

`post-update-check.sh` runs automatically after OpenClaw updates:
- Detects version changes
- Triggers full `patch-openclaw.sh` pipeline
- Writes version marker to prevent duplicate runs

```bash
# Cron (5 AM daily)
0 5 * * * ~/.openclaw/my-patches/nightly-scan.sh >> ~/.openclaw/my-patches/nightly.log 2>&1
```

---

## Analysis

Deep analysis reports in [`docs/analysis/`](docs/analysis/):

- **[PR Overlap Analysis](docs/analysis/2026-02-26-pr-overlap-analysis.md)** -- Duplicate/overlap detection across patches
- **[Candidate PRs](docs/analysis/2026-02-26-candidate-prs.md)** -- New candidates from nightly scoring
- **[Core Improvements](docs/analysis/2026-02-26-core-improvements.md)** -- Systematic review of OpenClaw improvement areas

---

## Files

```
openclaw-patchkit/
|-- README.md
|-- LICENSE                          # MIT
|-- pr-patches.conf                  # 94 PR patches + 3 FIX + 4 expansions
|-- patch-openclaw.sh                # Unified 4-phase orchestrator
|-- rebuild-with-patches.sh          # Phase 1: source rebuild (5-strategy cascade)
|-- dist-patches.sh                  # Phase 2: compiled JS patches + cognitive memory
|-- post-update-check.sh             # Auto-patch after OpenClaw updates
|-- discover-patches.sh              # Scan GitHub for new PRs
|-- nightly-scan.sh                  # Automated nightly scan + scoring + Discord reports
|-- health-monitor.sh                # Gateway health checker
|-- notify.sh                        # Notification helper
|-- install-sudoers.sh               # Passwordless sudo for patch scripts
|-- cognitive-memory-patch.sh        # Standalone cognitive memory installer
|-- scan-registry.json               # 4,300+ scored PRs with metadata
|-- manual-patches/                  # 42 scripts
|   |-- <PR_NUM>-<name>.sh          # 34 PR-based manual patches
|   |-- FIX-A{1,2,3}-*.sh           # 3 environment-specific fixes
|   +-- EXP-{1,2,3,4}-*.sh          # 4 custom expansions
|-- cognitive-memory-backup/         # Patched + original memory files
|-- docs/
|   |-- cognitive-memory-specs.md    # Implementation specs
|   +-- analysis/                    # Deep analysis reports
+-- research/
    |-- scientific-validation.md     # Peer-reviewed evidence
    +-- msam-analysis.md             # MSAM deep dive
```

## Upgrade Policy

- **Stay on current base** until PR merges reduce patch count or a critical security fix is needed
- **v2026.2.25 skipped**: 0 PRs merged, 2 conflicts, TS 7.0.0-dev risk. Waiting for v2026.2.26+
- When upgrading: run `rebuild-with-patches.sh` which auto-detects merged/closed PRs and adjusts
- PR close != removal: closed PRs stay in patchkit if the fix is still valuable

## Maintenance

- PRs **merged upstream** are marked in `pr-patches.conf` and excluded from rebuild
- PRs **closed upstream** are kept if the fix is still valid (close != remove)
- Patches with **context conflicts** on new releases get manual patch scripts
- New high-value PRs are discovered via nightly scan with apply-check
- Expansion scripts are independent and additive -- safe to enable/disable individually
- Manual patches are idempotent (safe to re-run)
- `pr-patches.conf` is the single source of truth for tracked patches
- `patch-openclaw.sh --status` shows last pipeline run results

## Disclaimer

This repository contains only tooling scripts, patch metadata, research documents, and build automation. It does **not** include OpenClaw source code or patched binaries.

[OpenClaw](https://github.com/openclaw/openclaw) is developed by its maintainers. Patches reference open PRs submitted by various contributors.

## License

[MIT](LICENSE)
