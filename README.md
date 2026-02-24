# OpenClaw Patchkit

Curated bug-fix patches for [OpenClaw](https://github.com/openclaw/openclaw), selected from 4000+ open PRs using AI-powered scoring ([Treliq](https://github.com/mahsumaktas/treliq) + Sonnet 4.6). Includes a research-backed **Cognitive Memory** enhancement.

## Current State

| Metric | Value |
|--------|-------|
| Base version | **v2026.2.23** |
| PRs scanned | 4,320 |
| PRs scored (Sonnet 4.6) | 4,051 |
| Patches tracked | 86 |
| Successfully applied | **47** |
| Merged upstream | 4 (auto-removed) |
| Closed upstream | 31 (auto-skipped) |
| Manual patch scripts | 15 |
| Waves | 4 |
| Last updated | 2026-02-25 |

> **Note:** Not all tracked patches apply cleanly to every release. The rebuild script automatically skips closed PRs and reports failures. See [Application Results](#application-results-v2026223) for details.

## Quick Start

```bash
# Clone
git clone https://github.com/mahsumaktas/openclaw-patchkit.git
cd openclaw-patchkit

# Apply PR patches (requires OpenClaw source at ../claude-code)
./rebuild-with-patches.sh

# Apply Cognitive Memory patch (works on installed OpenClaw)
./cognitive-memory-patch.sh
```

---

## Application Results (v2026.2.23)

On the latest release (v2026.2.23), rebuild-with-patches.sh produces:

| Category | Count | Notes |
|----------|-------|-------|
| Applied (clean) | 42 | Direct `git apply` |
| Applied (manual recovery) | 5 | Exclude-tests or manual patch |
| **Total applied** | **47** | |
| Skipped (closed upstream) | 31 | PRs closed without merge |
| Skipped (merged upstream) | 4 | #24559, #24594, #24795, #24761 |
| Failed (context mismatch) | 8 | Low priority or pre-existing |

The 8 failures are either low-priority fixes (#22900 Discord sed compat), already fixed differently upstream (#22741), or pre-existing issues from the base version.

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

Organized in 4 waves. Each patch corresponds to an open (or recently closed) PR in the OpenClaw repo.

### Wave 1: Hand-picked Critical Fixes (9 active)
Model allowlist, agent routing, PID cleanup, session contention, security hardening. 2 patches merged upstream in v2026.2.23.

### Wave 2: Systematic Scan (12 active)
Config safety, compaction repair, prompt injection prevention, session crash guards.

### Wave 3: Comprehensive Treliq Scan (24 active)
2250 PRs scored with Treliq + Haiku. Categories:
- **Security** (7): prototype pollution, auth header leaks, cron permissions, filename injection
- **Stability** (6): fetch timeouts, heartbeat dedup, memory leaks, error handling
- **Memory** (4): flush fix, double compaction guard, session store race
- **Agent/Session** (5): crash guards, path traversal, session cleanup
- **Gateway/Channel** (5): Discord fixes, delivery recovery, Unicode handling

### Wave 4: Sonnet 4.6 Full Scan (36 active)
4051 PRs re-scored with Sonnet 4.6. 2 patches merged upstream in v2026.2.23. Categories:
- **Security** (3): cross-channel reply routing, auth rate limiting, OAuth scope classification
- **Gateway** (5): LaunchAgent CA certs, pairing requestId, config env var preservation, loopback RPC, TLS scheme
- **Stability** (8): billing failover, empty content blocks, error payload filtering, FD exhaustion prevention
- **Provider/Model** (6): Bedrock compatibility, model fallback resolution, DashScope/Qwen compat, video/audio input
- **Channel** (5): Telegram crash replay, colon provider IDs, reaction filtering, reminder guard leak
- **Other** (9): config coercion, tool group validation, chat transcript persistence, stale metadata cleanup

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

A separate [Treliq nightly pipeline](https://github.com/mahsumaktas/treliq) also runs cumulative scoring with GitHub API integration, score caching, and ready-to-steal tracking.

```bash
# Cron (5 AM daily)
0 5 * * * ~/.openclaw/my-patches/nightly-scan.sh >> ~/.openclaw/my-patches/nightly.log 2>&1
```

---

## Files

```
openclaw-patchkit/
|-- README.md
|-- LICENSE                          # MIT
|-- pr-patches.conf                  # Tracked PR patches (86 active)
|-- rebuild-with-patches.sh          # Main build script
|-- discover-patches.sh              # Scan GitHub for new PRs
|-- nightly-scan.sh                  # Automated nightly scan
|-- cognitive-memory-patch.sh        # Cognitive Memory enhancement
|-- scan-registry.json               # Scan results with scores
|-- manual-patches/                  # 15 complex patch scripts
|-- cognitive-memory-backup/         # Patched + original files
|-- docs/
|   +-- cognitive-memory-specs.md    # Detailed implementation specs
+-- research/
    |-- scientific-validation.md     # Peer-reviewed evidence
    +-- msam-analysis.md             # MSAM deep dive & design
```

## Maintenance

Patch count changes over time:
- PRs **merged upstream** are marked in `pr-patches.conf` and excluded from rebuild
- PRs **closed upstream** are auto-skipped by the rebuild script (still tracked for reference)
- Patches with **context conflicts** on new releases may need manual adjustment
- New high-value PRs are discovered via nightly scan

`pr-patches.conf` is the single source of truth for tracked patches.

## Disclaimer

This repository contains only tooling scripts, patch metadata, research documents, and build automation. It does **not** include OpenClaw source code or patched binaries.

[OpenClaw](https://github.com/openclaw/openclaw) is developed by its maintainers. Patches reference open PRs submitted by various contributors.

## License

[MIT](LICENSE)
