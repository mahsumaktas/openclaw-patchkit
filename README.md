# OpenClaw Patchkit

Curated patches for [OpenClaw](https://github.com/anthropics/claude-code) from 4300+ open PRs, scored with [Treliq](https://github.com/mahsumaktas/treliq), tested against the latest release. Plus a **Cognitive Memory** enhancement backed by peer-reviewed research.

## Overview

| Metric | Count |
|--------|-------|
| PRs scanned | 4300+ |
| PRs scored (Treliq) | 2250 |
| PR patches | 52 |
| Custom patches | 6 |
| Waves | 3 |
| Base version | v2026.2.22 |

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
| **Category-based Decay** | Memories fade at different rates: `preference/entity = never`, `fact = very slow`, `decision = medium`, `other = fast` | MaRS benchmark (Dec 2025, 300 runs), Mem0 production |

### How It Works

```
Query → Vector Search → Dormant Filter → Activation Scoring → Confidence Gate → Results
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

## PR Patches (52)

Organized in 3 waves, each progressively broader:

### Wave 1: Critical Fixes (12)
Hand-picked: model allowlist, agent routing, PID cleanup, session contention, security hardening.

### Wave 2: Systematic Scan (12)
Full PR scan results: config safety, compaction repair, prompt injection prevention, session crash guards.

### Wave 3: Comprehensive Treliq Scan (28)
2250 PRs scored with Treliq. Categories:
- **Security** (7): prototype pollution, auth header leaks, cron permissions, filename injection
- **Stability** (6): fetch timeouts, heartbeat dedup, memory leaks, error handling
- **Memory** (4): flush fix, double compaction guard, session store race
- **Agent/Session** (5): crash guards, path traversal, session cleanup
- **Gateway/Channel** (5): Discord fixes, delivery recovery, Unicode handling
- **Other** (5): surrogate pairs, NaN guards, content markers

### Application Methods

| Method | Count | Description |
|--------|-------|-------------|
| `git apply` (clean) | 28 | Direct application |
| `git apply --exclude tests` | 10 | Excluding test files |
| `git apply --exclude changelog` | 2 | Excluding changelog |
| Manual patch scripts | 6 | Complex patches in `manual-patches/` |

## Files

```
openclaw-patchkit/
├── README.md
├── LICENSE                          # MIT
├── pr-patches.conf                  # Master list of 52 PR patches
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
│   └── 24583-strip-external-content.sh
├── docs/
│   └── cognitive-memory-specs.md    # Detailed implementation specs
└── research/
    ├── scientific-validation.md     # Peer-reviewed evidence
    └── msam-analysis.md             # MSAM deep dive & design
```

## Automation

### Nightly Scan

`nightly-scan.sh` automatically:
1. Fetches new/updated PRs from OpenClaw repo
2. Scores each PR with Treliq (relevance, risk, merge-readiness)
3. Tests application against current base version
4. Updates `scan-registry.json`
5. Flags high-scoring candidates for review

```bash
# Manual run
./nightly-scan.sh

# Cron (every night at 3am)
0 3 * * * /path/to/openclaw-patchkit/nightly-scan.sh >> /tmp/patchkit-scan.log 2>&1
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
