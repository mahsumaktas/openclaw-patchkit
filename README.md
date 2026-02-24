# OpenClaw Patchkit

Curated patches for [OpenClaw](https://github.com/openclaw/openclaw) from 4300+ open PRs, scored with Sonnet 4.6 via [Treliq](https://github.com/mahsumaktas/treliq), tested against the latest release. Plus a **Cognitive Memory** enhancement backed by peer-reviewed research.

## Overview

| Metric | Count |
|--------|-------|
| PRs scanned (GraphQL) | 4,320 |
| PRs scored (Sonnet 4.6) | 4,051 |
| PR patches | 90 |
| Manual patch scripts | 15 |
| Waves | 4 |
| Base version | v2026.2.22 |
| Last updated | 2026-02-24 |

## Quick Start

```bash
# Clone
git clone https://github.com/mahsumaktas/openclaw-patchkit.git
cd openclaw-patchkit

# Apply PR patches (requires OpenClaw source at ../claude-code)
./rebuild-with-patches.sh

# Apply Cognitive Memory patch (works on installed OpenClaw)
./manual-patches/cognitive-memory-patch.sh
```

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
Query → Content Hash Check → Vector Search → Dormant Filter → Activation Scoring → Confidence Gate → Results (with relatedTo IDs)
                                              ↓
                              score = 0.5 × similarity
                                    + 0.35 × sigmoid(ln(accessCount) - 0.5 × ln(age))
                                    + 0.15 × importance
                                              ↓
                              if bestScore < 0.35 → return nothing (save tokens)
                              else → return top-k, update accessCount, boost stability
```

Memory lifecycle:
```
active → fading → dormant
  ↑         |
  └─────────┘ (recalled = reactivated, stability × 1.2)
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
openclaw ltm decay    # Run decay cycle (transition fading → dormant)
openclaw ltm revive <id>  # Reactivate a dormant memory
openclaw ltm stats    # Show memory count
```

### Research

Full analysis in [`research/`](research/):

- **[Scientific Validation](research/scientific-validation.md)** — Evidence review for each technique (ACT-R, Self-RAG, MaRS, Ebbinghaus)
- **[MSAM Analysis](research/msam-analysis.md)** — Deep dive into Multi-Stream Adaptive Memory, what to keep and what to discard
- **[Implementation Specs](docs/cognitive-memory-specs.md)** — Detailed PR specifications with pseudocode

---

## PR Patches (90)

Organized in 4 waves, each progressively broader:

### Wave 1: Critical Fixes (12)
Hand-picked: model allowlist, agent routing, PID cleanup, session contention, security hardening.

### Wave 2: Systematic Scan (12)
Full PR scan results: config safety, compaction repair, prompt injection prevention, session crash guards.

### Wave 3: Comprehensive Treliq Scan (28)
2250 PRs scored with Treliq + Haiku. Categories:
- **Security** (7): prototype pollution, auth header leaks, cron permissions, filename injection
- **Stability** (6): fetch timeouts, heartbeat dedup, memory leaks, error handling
- **Memory** (4): flush fix, double compaction guard, session store race
- **Agent/Session** (5): crash guards, path traversal, session cleanup
- **Gateway/Channel** (5): Discord fixes, delivery recovery, Unicode handling

### Wave 4: Sonnet 4.6 Full Scan (38)
4051 PRs re-scored with Sonnet 4.6. New finds:
- **Security** (3): cross-channel reply routing, auth rate limiting, OAuth scope classification
- **Gateway** (5): LaunchAgent CA certs, pairing requestId, config env var preservation, loopback RPC, TLS scheme
- **Stability** (8): billing failover, empty content blocks, error payload filtering, FD exhaustion prevention
- **Provider/Model** (6): Bedrock compatibility, model fallback resolution, DashScope/Qwen compat, video/audio input
- **Channel** (5): Telegram crash replay, colon provider IDs, reaction filtering, reminder guard leak
- **Other** (11): config coercion, tool group validation, chat transcript persistence, stale metadata cleanup

### Application Methods

| Method | Count | Description |
|--------|-------|-------------|
| `git apply` (clean) | 55 | Direct application |
| `git apply --exclude tests` | 14 | Excluding test files |
| `git apply --exclude changelog` | 6 | Excluding changelog |
| Manual patch scripts | 15 | Complex patches in `manual-patches/` |

### Score Distribution (4051 PRs)

| Score Range | Count |
|-------------|-------|
| 85+ | 2 |
| 80-84 | 100 |
| 75-79 | 558 |
| 70-74 | 962 |
| <70 | 2429 |

## Files

```
openclaw-patchkit/
├── README.md
├── LICENSE                          # MIT
├── pr-patches.conf                  # Master list of 90 PR patches
├── rebuild-with-patches.sh          # Main build script
├── discover-patches.sh              # Scan GitHub for new PRs
├── nightly-scan.sh                  # Automated nightly scan
├── scan-registry.json               # Scan results with scores
├── manual-patches/
│   ├── cognitive-memory-patch.sh    # Cognitive Memory enhancement
│   ├── cognitive-memory-backup/     # Patched + original files
│   ├── 16609-session-store-race.sh
│   ├── 16894-surrogate-truncation.sh
│   ├── 19675-zero-width-unicode.sh
│   ├── 22901-nan-reservetokens.sh
│   ├── 24583-strip-external-content.sh
│   ├── 17371-heartbeat-strip.sh
│   ├── 22900-discord-v2-flag.sh
│   ├── 19134-sse-utf8.sh
│   ├── 16987-skipcache-session-store.sh
│   ├── 21847-session-model-overrides.sh
│   ├── 17435-debounce-retry.sh
│   ├── 16015-truncate-chat-history.sh
│   ├── 17823-cron-maps-cleanup.sh
│   ├── 20867-video-audio-input.sh
│   └── 11986-empty-assistant-content.sh
├── docs/
│   └── cognitive-memory-specs.md    # Detailed implementation specs
└── research/
    ├── scientific-validation.md     # Peer-reviewed evidence
    └── msam-analysis.md             # MSAM deep dive & design
```

## Automation

### Nightly Scan

`nightly-scan.sh` runs at 5 AM daily via cron:
1. Fetches PRs updated in the last 3 days from the OpenClaw repo
2. Filters against scan registry to skip already-scored PRs
3. Scores new PRs using Treliq + Sonnet 4.6
4. Checks if patched PRs have been merged upstream (removes if so)
5. Updates `scan-registry.json` and pushes to this repo
6. Flags high-scoring candidates for manual review

```bash
# Cron (5 AM daily)
0 5 * * * ~/.openclaw/my-patches/nightly-scan.sh >> ~/.openclaw/my-patches/nightly.log 2>&1
```

## Maintenance

Patch count changes over time:
- PRs **merged upstream** are automatically skipped by the rebuild script
- Patches found **unnecessary or incompatible** are removed (tracked in commit history)
- New high-value PRs are added via nightly scan

`pr-patches.conf` is the single source of truth for active patches.

## Disclaimer

This repository contains only tooling scripts, patch metadata, research documents, and build automation. It does **not** include OpenClaw source code or patched binaries.

[OpenClaw](https://github.com/anthropics/claude-code) is developed by Anthropic and licensed under the Apache License 2.0.

## License

[MIT](LICENSE)
