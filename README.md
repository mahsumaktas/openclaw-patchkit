# OpenClaw Patchkit

Curated bug-fix patches for [OpenClaw](https://github.com/openclaw/openclaw), selected from 4000+ open PRs using AI-powered scoring ([Treliq](https://github.com/mahsumaktas/treliq) + Sonnet 4.6). Includes a research-backed **Cognitive Memory** enhancement.

## Current State

| Metric | Value |
|--------|-------|
| Base version | **v2026.2.23** |
| PRs scanned | 4,320 |
| PRs scored (Sonnet 4.6) | 4,051 |
| Patches tracked | **57** |
| Successfully applied | **57/57 (100%)** |
| Build status | **771 files compiled** |
| Merged upstream | 2 (auto-removed) |
| Manual patch scripts | 17 |
| Waves | 5 |
| Last updated | 2026-02-25 |

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
Phase 1: Source Rebuild    → 57 PR diffs applied, TypeScript build, dist swap
Phase 2: Dist Patches      → TLS probe, self-signed cert, LanceDB deps
Phase 3: Extension Patches → Cognitive Memory enhancement
Phase 4: Verification      → 5 automated checks (entry.js, TLS, cert, memory, version)
```

### 5-Strategy Cascade (Phase 1)

Each PR diff is tried with increasingly relaxed strategies until one succeeds:

| Strategy | Description | Count |
|----------|-------------|-------|
| 1. Clean apply | `git apply` — exact match | 34 |
| 2. Exclude tests | `--exclude '*.test.*'` | 8 |
| 3. Exclude changelog+tests | `--exclude 'CHANGELOG.md'` + tests | 2 |
| 4. 3-way merge | `git apply --3way` | 0 |
| 5. Manual patch | Custom bash/python3 scripts | 17 |
| **Total** | | **57/57** |

---

## Application Results (v2026.2.23)

| Category | Count | Notes |
|----------|-------|-------|
| Applied (clean) | 34 | Direct `git apply` |
| Applied (exclude tests) | 8 | Test files excluded |
| Applied (exclude changelog+tests) | 2 | CHANGELOG context drift |
| Applied (manual patch) | 13 | Custom scripts for context mismatches |
| **Total applied** | **57** | **0 failures** |
| Build output | 771 files | TypeScript compilation |
| Verification | 5/5 | All checks passed |

---

## Cognitive Memory Patch

A research-backed enhancement to OpenClaw's `memory-lancedb` plugin that adds cognitive scoring, confidence gating, and memory lifecycle management.

### Features

| Feature | What it does | Evidence |
|---------|-------------|----------|
| **Activation Scoring** | Ranks memories by `similarity (50%) + recency x frequency (35%) + importance (15%)` instead of pure vector distance | ACT-R cognitive model ([Anderson et al.](https://doi.org/10.1037/0033-295X.111.4.1036)), Park et al. 2023, Mem0 production |
| **Confidence Gating** | Returns nothing when best match scores below threshold, preventing irrelevant context injection | Self-RAG (Asai et al., [ICLR 2024](https://arxiv.org/abs/2310.11511)), FLARE (Jiang et al., 2023) |
| **Semantic Dedup** | Merges near-duplicate memories (0.85 threshold) instead of rejecting at 0.95, updates text to latest version | Standard IR deduplication |
| **Content Hash Dedup** | sha256-based exact dedup before embedding check, zero-cost rejection of identical memories | Deterministic, no false positives |
| **Related-To Linking** | Bidirectional links between memories with 0.60-0.84 similarity, surfaced on recall | memU-inspired cross-referencing |
| **Category-based Decay** | Memories fade at different rates: `preference/entity = never`, `fact = very slow`, `decision = medium`, `other = fast` | MaRS benchmark (Dec 2025, 300 runs), Mem0 production |

### How It Works

```
Query -> Content Hash Check -> Vector Search -> Dormant Filter -> Activation Scoring -> Confidence Gate -> Results (with relatedTo IDs)
                                                |
                                score = 0.5 x similarity
                                      + 0.35 x sigmoid(ln(accessCount) - 0.5 x ln(age))
                                      + 0.15 x importance
                                                |
                                if bestScore < 0.35 -> return nothing (save tokens)
                                else -> return top-k, update accessCount, boost stability
```

Memory lifecycle:
```
active -> fading -> dormant
  |         |
  +----<----+ (recalled = reactivated, stability x 1.2)
```

### Configuration

All options are optional with sensible defaults. Add to your OpenClaw memory config:

```json
{
  "similarityWeight": 0.50,
  "activationWeight": 0.35,
  "importanceWeight": 0.15,
  "confidenceThreshold": 0.35,
  "deduplicationThreshold": 0.85,
  "decayEnabled": true,
  "decayOnStartup": true
}
```

### CLI Commands

```bash
openclaw ltm decay    # Run decay cycle (transition fading -> dormant)
openclaw ltm revive <id>  # Reactivate a dormant memory
openclaw ltm stats    # Show memory count
```

### Research

Full analysis in [`research/`](research/):

- **[Scientific Validation](research/scientific-validation.md)** — Evidence review for each technique (ACT-R, Self-RAG, MaRS, Ebbinghaus)
- **[MSAM Analysis](research/msam-analysis.md)** — Deep dive into Multi-Stream Adaptive Memory, what to keep and what to discard
- **[Implementation Specs](docs/cognitive-memory-specs.md)** — Detailed PR specifications with pseudocode

---

## PR Patches

Organized in 5 waves across 57 active patches.

### Wave 1: Hand-picked Critical Fixes (7 active)
Model allowlist, agent routing, PID cleanup, session contention, security hardening.

### Wave 2: Systematic Scan (8 active)
Config safety, compaction repair, prompt injection prevention, session crash guards. Includes 2 manual patches for Unicode handling.

### Wave 3: Comprehensive Treliq Scan (19 active)
2250 PRs scored with Treliq + Haiku. Categories:
- **Security** (4): prototype pollution, auth header leaks, cron permissions, filename injection
- **Stability** (5): fetch timeouts, heartbeat dedup, error handling, connection classification
- **Memory/Session** (4): flush fix, session store, BM25 scoring, stale model info
- **Gateway/Channel** (6): Discord v2 flags, SSE encoding, oversized messages, WebSocket 429

### Wave 4: Sonnet 4.6 Full Scan (17 active)
4051 PRs re-scored with Sonnet 4.6. Categories:
- **Security** (1): auth rate limiting
- **Gateway** (4): LaunchAgent CA certs, pairing requestId, config env var preservation, TLS scheme
- **Stability** (4): billing failover, error payload filtering, FD exhaustion prevention, type arrays
- **Provider/Model** (3): Bedrock video/audio, colon provider IDs, codex usage window
- **Channel** (4): Telegram reaction filtering, auto-reply guard, logger binding, audio MIME mappings
- **Other** (1): archived transcript usage costs

### Wave 5: Tier 1 Batch (6 active)
Score >= 80 from curated report. Categories:
- **Onboarding** (1): fallback install for missing channel plugin
- **Security** (1): doctor TLS warning for network-exposed gateway
- **Hooks** (2): sessionKey in hook context, configured model for slug generator
- **Cron** (1): disable messaging when delivery.mode=none
- **Merged/Closed** (removed): #24300, #12499, #12792, #23974

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
1. Fetches PRs updated in the last 3 days from the OpenClaw repo
2. Filters against scan registry to skip already-scored PRs
3. Scores new PRs using Treliq + Sonnet 4.6
4. Checks if patched PRs have been merged upstream
5. Updates `scan-registry.json` and pushes to this repo

```bash
# Cron (5 AM daily)
0 5 * * * ~/.openclaw/my-patches/nightly-scan.sh >> ~/.openclaw/my-patches/nightly.log 2>&1
```

### Post-Update Check

`post-update-check.sh` runs automatically after OpenClaw updates to re-apply patches:
- Detects version changes
- Triggers full `patch-openclaw.sh` pipeline
- Writes version marker to prevent duplicate runs

---

## Files

```
openclaw-patchkit/
|-- README.md
|-- LICENSE                          # MIT
|-- pr-patches.conf                  # 57 active PR patches (single source of truth)
|-- patch-openclaw.sh                # Unified 4-phase orchestrator
|-- rebuild-with-patches.sh          # Phase 1: source rebuild (5-strategy cascade)
|-- dist-patches.sh                  # Phase 2: compiled JS patches
|-- post-update-check.sh             # Auto-patch after OpenClaw updates
|-- discover-patches.sh              # Scan GitHub for new PRs
|-- nightly-scan.sh                  # Automated nightly scan + scoring
|-- scan-registry.json               # 4051 scored PRs with metadata
|-- manual-patches/                  # 17 complex PR patch scripts + 1 extension
|   |-- cognitive-memory-patch.sh    # Cognitive Memory enhancement
|   |-- cognitive-memory-backup/     # Patched + original files
|   +-- NNNNN-description.sh         # Per-PR manual patches
|-- docs/
|   +-- cognitive-memory-specs.md    # Detailed implementation specs
+-- research/
    |-- scientific-validation.md     # Peer-reviewed evidence
    +-- msam-analysis.md             # MSAM deep dive & design
```

## Maintenance

Patch count changes over time:
- PRs **merged upstream** are marked in `pr-patches.conf` and excluded from rebuild
- PRs **closed upstream** are auto-skipped by the rebuild script
- Patches with **context conflicts** on new releases get manual patch scripts
- New high-value PRs are discovered via nightly scan
- `patch-openclaw.sh --status` shows last pipeline run results

`pr-patches.conf` is the single source of truth for tracked patches.

## Disclaimer

This repository contains only tooling scripts, patch metadata, research documents, and build automation. It does **not** include OpenClaw source code or patched binaries.

[OpenClaw](https://github.com/openclaw/openclaw) is developed by its maintainers. Patches reference open PRs submitted by various contributors.

## License

[MIT](LICENSE)
