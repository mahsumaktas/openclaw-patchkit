# OpenClaw Patchkit

Curated bug-fix patches for [OpenClaw](https://github.com/openclaw/openclaw), selected from 4000+ open PRs using AI-powered scoring ([Treliq](https://github.com/mahsumaktas/treliq) + Sonnet 4.6). Includes a research-backed **Cognitive Memory v3** enhancement and **4 custom core expansions** (webhook deduplication, pre-auth firewall, graceful lifecycle, resilient connections).

## Current State

| Metric | Value |
|--------|-------|
| Base version | **v2026.2.24** |
| PRs scanned | 4,320 |
| PRs scored (Sonnet 4.6) | 4,051 |
| PR patches tracked | **74** |
| Custom expansions | **4** |
| Successfully applied | **74/74 PRs + 4 expansions (100%)** |
| Build status | **768 files compiled** |
| Manual patch scripts | 25 (21 PR + 4 expansion) |
| Cognitive Memory | **v3** (entity extraction, enforced RAG, hybrid capture) |
| Waves | 8 + Expansions |
| Last updated | 2026-02-26 |

## Quick Start

```bash
# Clone
git clone https://github.com/mahsumaktas/openclaw-patchkit.git
cd openclaw-patchkit

# Full pipeline (rebuild + dist patches + extensions + verify)
./patch-openclaw.sh

# Or run individual phases:
./patch-openclaw.sh --phase 1    # Source rebuild only
./patch-openclaw.sh --phase 2    # Dist patches only
./patch-openclaw.sh --phase 3    # Extension patches only
./patch-openclaw.sh --status     # Show last run report
./patch-openclaw.sh --dry-run    # Preview without changes
```

---

## Unified Patch Pipeline

`patch-openclaw.sh` orchestrates all patching in 4 phases:

```
Phase 1: Source Rebuild    → 74 PR diffs + 4 expansions applied, TypeScript build, dist swap
Phase 2: Dist Patches      → TLS probe, self-signed cert, LanceDB deps, Cognitive Memory
Phase 3: Extension Patches → Cognitive Memory (fallback if Phase 2 handled it)
Phase 4: Verification      → 6 automated checks (entry.js, TLS, cert, memory, LanceDB, version)
```

### 5-Strategy Cascade (Phase 1)

Each PR diff is tried with increasingly relaxed strategies until one succeeds:

| Strategy | Description | Count |
|----------|-------------|-------|
| 1. Manual patch | Custom bash/python3 scripts | 25 |
| 2. Clean apply | `git apply` — exact match | 39 |
| 3. Exclude tests | `--exclude '*.test.*'` | 8 |
| 4. Exclude changelog+tests | `--exclude 'CHANGELOG.md'` + tests | 2 |
| 5. 3-way merge | `git apply --3way` | 0 |
| **Total** | | **74 PRs + 4 expansions** |

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

4-phase shutdown orchestration: DRAIN → FLUSH → CLEANUP → EXIT. Includes startup validation (port availability, config file checks), signal handling (SIGTERM/SIGINT), and configurable per-phase timeouts. Opt-in wrapper that doesn't modify existing `server-close.ts` — adds orchestration layer on top.

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

## Cognitive Memory v3

A research-backed enhancement to OpenClaw's `memory-lancedb` plugin. v3 adds entity extraction, enforced RAG with entity boost, and a hybrid capture pipeline on top of the proven v2 cognitive scoring foundation.

### v3 Features (NEW)

| Feature | What it does |
|---------|-------------|
| **Entity Extraction** | Regex NER extracts person, tech, org, project, location entities with canonical URIs (`entity://type/slug`). Turkish + English. Zero dependencies, <5ms. |
| **Enforced RAG** | Smart memory injection on every prompt. Threshold 0.75, top-K 3, +0.1 score boost per entity overlap. ~600 tokens/prompt. |
| **Hybrid Capture Pipeline** | 3-layer: heuristic scoring (5 patterns) → decision logic (>=0.5 direct, 0.2-0.5 uncertain) → LLM verify (gpt-4o-mini, ~30% of messages). |
| **Agent Tagging** | Every memory tagged with `sourceAgent` (hachiko, scout, analyst, etc). Shared pool, agent-specific display in context. |
| **LLM Verification** | Uncertain captures verified by gpt-4o-mini. Stores `llmVerified` flag and LLM-assigned importance. |

### v2 Foundation (Proven)

| Feature | What it does | Evidence |
|---------|-------------|----------|
| **Activation Scoring** | Ranks memories by `similarity (50%) + recency x frequency (35%) + importance (15%)` | ACT-R cognitive model ([Anderson et al.](https://doi.org/10.1037/0033-295X.111.4.1036)) |
| **Confidence Gating** | Returns nothing when best match scores below threshold | Self-RAG ([ICLR 2024](https://arxiv.org/abs/2310.11511)) |
| **Semantic Dedup** | Merges near-duplicate memories (0.85 threshold), updates text to latest version | Standard IR deduplication |
| **Content Hash Dedup** | sha256-based exact dedup before embedding check | Deterministic, zero false positives |
| **Related-To Linking** | Bidirectional links between memories with 0.60-0.84 similarity | Cross-referencing |
| **Category-based Decay** | `preference/entity = never`, `fact = very slow`, `decision = medium`, `other = fast` | Batch updates (N+1 fix in v3) |

### Schema (v3 — 16 fields)

```
id, text, vector, importance, category, createdAt, accessCount, lastAccessed,
stability, state, contentHash, relatedTo, entities, sourceAgent, captureScore, llmVerified
```

Auto-migration from v1 and v2 schemas (probe-based detection).

### How It Works

```
Enforced RAG (before_agent_start):
  Query → Embed → Extract Entities → Vector Search (2x candidates, 0.6 threshold)
       → Entity Boost (+0.1/overlap) → Filter >= 0.75 → Top-K 3 → Inject Context

Capture Pipeline (agent_end):
  User Messages → Pre-filter → Extract Entities → Heuristic Score
       → Score >= 0.5: Direct Capture
       → 0.2-0.5: LLM Verify (gpt-4o-mini) → Capture if approved
       → < 0.2: Skip
       → Content Hash Dedup → Semantic Dedup → Store with entities + agent tag

Memory Lifecycle:
  active → fading → dormant (batch decay, category-based rates)
    ↑         ↑
    +----<----+ (recalled = reactivated, stability x 1.2)
```

### Configuration

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

- **[Scientific Validation](research/scientific-validation.md)** — Evidence review (ACT-R, Self-RAG, MaRS, Ebbinghaus)
- **[MSAM Analysis](research/msam-analysis.md)** — Multi-Stream Adaptive Memory deep dive
- **[v3 Design](docs/cognitive-memory-specs.md)** — Implementation specs

---

## PR Patches

Organized in 8 waves across 74 active patches.

### Wave 1: Hand-picked Critical Fixes (7 active)
Model allowlist, agent routing, PID cleanup, session contention, security hardening.

### Wave 2: Systematic Scan (7 active)
Config safety, compaction repair, prompt injection prevention, session crash guards. Includes 2 manual patches for Unicode handling.

### Wave 3: Comprehensive Treliq Scan (18 active)
2250 PRs scored with Treliq + Haiku. Categories:
- **Security** (4): prototype pollution, auth header leaks, cron permissions, filename injection
- **Stability** (5): fetch timeouts, heartbeat dedup, error handling, connection classification
- **Memory/Session** (4): flush fix, session store, BM25 scoring, stale model info
- **Gateway/Channel** (5): Discord v2 flags, SSE encoding, oversized messages, WebSocket 429

### Wave 4: Sonnet 4.6 Full Scan (17 active)
4051 PRs re-scored with Sonnet 4.6. Categories:
- **Security** (1): auth rate limiting
- **Gateway** (4): LaunchAgent CA certs, pairing requestId, config env var preservation, TLS scheme
- **Stability** (4): billing failover, error payload filtering, FD exhaustion prevention, type arrays
- **Provider/Model** (3): Bedrock video/audio, colon provider IDs, codex usage window
- **Channel** (4): Telegram reaction filtering, auto-reply guard, logger binding, audio MIME mappings
- **Other** (1): archived transcript usage costs

### Wave 5: Tier 1 Batch (3 active)
Score >= 80 from curated report. TLS warning, hook context, cron delivery mode.

### Wave 6: Deep Review Batch (9 active)
Reviewed and approved patches. Gateway stop fix, echo loop prevention, hook agentId enforcement, session corruption prevention, orphan tool result cleanup, cron write drain, BM25 minScore cap, child run finalization, heartbeat transcript preservation.

### Wave 7: High-Risk Manual Patches (3 active)
Complex multi-file patches requiring custom scripts:
- **#24840**: env.vars redaction + network failover + CLI cookie-url fix
- **#25381**: Preserve thinking blocks in latest assistant during compaction (selective from 12-file PR)
- **#24517**: Shared workspace locking for multi-agent write safety (3 new files)

### Wave 8: Nightly Scan Batch (10 active, 4 skipped)
First batch discovered and applied via automated nightly scanning:
- **Security** (3): pre-auth WS handshake cap, pre-auth frame limit, group chat agent allowlist
- **Gateway** (3): KeepAlive plist fix, graceful drain mode, OpenAI ingress hard-bind
- **Stability** (3): streaming fetch error prevention, cron jobId normalization, double compaction guard
- **Channel** (1): Discord resume death spiral fix

Skipped: PID recycling (container-only), LINE dedupe (superseded by EXP-1), IRC monitor (superseded by EXP-4), RubberBand (XL, high risk).

### Score Distribution (4051 PRs)

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
2. Filters against scan registry — skips already-scored, re-checks recovered drafts
3. Scores new PRs using Treliq + Sonnet 4.6 (no line-count limit)
4. Runs `git apply --check` on high-score PRs to test patch applicability
5. Checks if patched PRs have been merged/closed upstream
6. Sends results to Discord with apply status tags (`[APPLY OK: strategy]` or `[NEEDS MANUAL]`)
7. Updates `scan-registry.json` and pushes to this repo

### Post-Update Check

`post-update-check.sh` runs automatically after OpenClaw updates to re-apply patches:
- Detects version changes
- Triggers full `patch-openclaw.sh` pipeline
- Writes version marker to prevent duplicate runs

---

## Analysis

Deep analysis reports in [`docs/analysis/`](docs/analysis/):

- **[PR Overlap Analysis](docs/analysis/2026-02-26-pr-overlap-analysis.md)** — Duplicate/overlap detection across 74 patches
- **[Candidate PRs](docs/analysis/2026-02-26-candidate-prs.md)** — Wave 9 candidates from 374 scored PRs
- **[Core Improvements](docs/analysis/2026-02-26-core-improvements.md)** — Systematic review of OpenClaw improvement areas

---

## Files

```
openclaw-patchkit/
|-- README.md
|-- LICENSE                          # MIT
|-- pr-patches.conf                  # 74 PR patches + 4 expansions (single source of truth)
|-- patch-openclaw.sh                # Unified 4-phase orchestrator
|-- rebuild-with-patches.sh          # Phase 1: source rebuild (5-strategy cascade)
|-- dist-patches.sh                  # Phase 2: compiled JS patches + cognitive memory
|-- post-update-check.sh             # Auto-patch after OpenClaw updates
|-- discover-patches.sh              # Scan GitHub for new PRs
|-- nightly-scan.sh                  # Automated nightly scan + scoring + Discord reports
|-- scan-registry.json               # 4051 scored PRs with metadata
|-- manual-patches/                  # 25 scripts (21 PR patches + 4 expansions)
|   |-- cognitive-memory-patch.sh    # Cognitive Memory v3 enhancement
|   |-- cognitive-memory-backup/     # Patched + original files (index.ts, config.ts)
|   |-- EXP-1-webhook-deduplicator.sh  # Expansion: webhook dedupe middleware
|   |-- EXP-2-gateway-firewall.sh      # Expansion: pre-auth firewall
|   |-- EXP-3-lifecycle-manager.sh     # Expansion: graceful lifecycle
|   |-- EXP-4-resilient-connection.sh  # Expansion: channel reconnect base class
|   +-- NNNNN-description.sh         # Per-PR manual patches
|-- docs/
|   |-- cognitive-memory-specs.md    # Implementation specs
|   +-- analysis/                    # Deep analysis reports
+-- research/
    |-- scientific-validation.md     # Peer-reviewed evidence
    +-- msam-analysis.md             # MSAM deep dive
```

## Maintenance

- PRs **merged upstream** are marked in `pr-patches.conf` and excluded from rebuild
- PRs **closed upstream** are auto-skipped by the rebuild script
- Patches with **context conflicts** on new releases get manual patch scripts
- New high-value PRs are discovered via nightly scan with apply-check
- Expansion scripts are independent and additive — safe to enable/disable individually
- `patch-openclaw.sh --status` shows last pipeline run results

`pr-patches.conf` is the single source of truth for tracked patches.

## Disclaimer

This repository contains only tooling scripts, patch metadata, research documents, and build automation. It does **not** include OpenClaw source code or patched binaries.

[OpenClaw](https://github.com/openclaw/openclaw) is developed by its maintainers. Patches reference open PRs submitted by various contributors.

## License

[MIT](LICENSE)
