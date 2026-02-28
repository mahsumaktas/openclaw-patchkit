# OpenClaw Patchkit

Stability-first patch management for [OpenClaw](https://github.com/openclaw/openclaw). 119 curated patches from 5,300+ scanned PRs, scored with Treliq and Sonnet 4.6. Automated upgrade pipeline with conflict pre-check, auto-retirement, and rollback.

> **"If it ain't broke, don't fix it."** Working system > theoretically better system.

---

## Disclaimer

**USE AT YOUR OWN RISK.** This patchkit is provided as-is, without warranty of any kind. Applying these patches to your OpenClaw installation is entirely your responsibility.

- Maintained for a specific macOS gateway setup. May not work in your environment.
- Always back up your installation before applying patches.
- Test in a non-production environment first.
- No guarantees about compatibility with future OpenClaw versions.

This repository contains only tooling scripts, patch metadata, and build automation. It does **not** include OpenClaw source code or patched binaries. [OpenClaw](https://github.com/openclaw/openclaw) is developed by its own maintainers.

---

## Current State

| Metric | Value |
|--------|-------|
| Base version | **v2026.2.26** |
| Active PR patches | **119** (categorized by function) |
| FIX scripts | **3** (macOS environment-specific) |
| Manual patch scripts | **63** (59 PR + 3 FIX + 1 cognitive memory) |
| Cognitive Memory | **v4** (self-pruning, entity graph, mood detection) |
| Extensions | **Externalized** to `~/.openclaw/extensions/` (upgrade-safe) |
| Scanned PRs | **5,329** across 14 waves |
| Disabled | 1 (#28258 -- stream wrapper crash) |
| Last update | 2026-02-28 (Hardened Patchkit) |

---

## Quick Start

```bash
# Clone
git clone https://github.com/mahsumaktas/openclaw-patchkit.git
cd openclaw-patchkit

# Full pipeline (rebuild + dist patches + extensions + verify)
sudo ./patch-openclaw.sh

# Individual phases
sudo ./patch-openclaw.sh --phase 1    # Source rebuild only
sudo ./patch-openclaw.sh --phase 2    # Dist patches only
sudo ./patch-openclaw.sh --phase 3    # Extension verification
sudo ./patch-openclaw.sh --status     # Last run report
sudo ./patch-openclaw.sh --dry-run    # Preview without changes
sudo ./patch-openclaw.sh --rollback   # Restore previous dist backup

# Pre-upgrade safety check
./pre-upgrade-check.sh v2026.2.27     # Conflict analysis before upgrading
```

**Requirements:** Node.js >= 22, pnpm, GitHub CLI (`gh`), macOS with LaunchAgent support.

---

## Architecture

### Upgrade Pipeline

```
OpenClaw upgrade detected (LaunchAgent watches package.json)
  |
  v
post-update-check.sh
  |-- Version marker check (.last-patched-version)
  |-- Discord: "Upgrade detected, applying patches..."
  |
  v
patch-openclaw.sh --skip-restart
  |-- Phase 1: rebuild-with-patches.sh
  |     |-- Auto-skip merged PRs (retirement pipeline)
  |     |-- 5-strategy cascade for remaining patches
  |     |-- TypeScript build + dist swap
  |
  |-- Phase 2: dist-patches.sh
  |     |-- TLS probe fingerprint
  |     |-- Carbon error handler (dual-layer)
  |     |-- WSS self-signed cert
  |     |-- LanceDB native bindings
  |     |-- #28258 safety net
  |
  |-- Phase 3: cognitive-memory-patch.sh
  |     |-- Extension integrity verification
  |     |-- v4 marker check (prune, entityGraph, mood, accessCount)
  |     |-- Auto-repair from bundled if missing
  |
  |-- Phase 4: Verification
        |-- entry.js, TLS, cert, memory, version
        |-- Retirement summary report
  |
  v
Gateway restart (SIGTERM + kickstart)
  |
  v
health-monitor.sh (5min watch, 3+ crash = auto-rollback)
```

### 5-Strategy Cascade (Phase 1)

| Priority | Strategy | When |
|----------|----------|------|
| 0 | **Manual script** | Custom bash/python3 -- handles context drift, import conflicts |
| 1 | Clean apply | `git apply` -- exact match |
| 2 | Exclude tests | `--exclude '*.test.*'` -- test context drift |
| 3 | Exclude changelog+tests | `--exclude 'CHANGELOG.md'` + tests |
| 4 | 3-way merge | `git apply --3way` -- last resort |

### Auto-Retirement

When a PR is merged upstream, the pipeline automatically:
1. **Detects** merge status via GitHub API during rebuild
2. **Skips** the patch (no longer needed)
3. **Logs** to `retired-patches.log` with timestamp and merge SHA
4. **Comments out** the entry in `pr-patches.conf`

Nightly scan also checks active patches for upstream merges and sends Discord alerts.

### Conflict Pre-check

Before upgrading, run `pre-upgrade-check.sh` to get a safety report:

```
Pre-upgrade Report: v2026.2.26 -> v2026.2.27
  OK  105 patches: no conflict expected
  !!    7 patches: file overlap detected
  xx    4 patches: merged upstream (retire candidates)
  ->    3 FIX scripts: manual review needed
```

Uses GitHub Compare API with git clone fallback for releases exceeding 300 changed files.

### Rollback

Three levels of rollback protection:
- **Manual:** `sudo ./patch-openclaw.sh --rollback` restores the previous dist backup
- **Auto:** `health-monitor.sh` triggers rollback after 3+ gateway crashes
- **Backup:** `dist-backup-{VERSION}/` directories preserved automatically

---

## Patch Categories

Patches are organized by function in `pr-patches.conf` with risk metadata:

```
PR_NUM  description  [risk:low|medium|high|critical] [verified:v2026.2.26]
```

| Category | Count | Description |
|----------|-------|-------------|
| **Security** | 14 | Zero-width bypass, prototype pollution, brute-force protection, secret detection, spoofed messages |
| **Gateway/Daemon** | 19 | Port conflicts, TLS crashes, graceful drain, PID cleanup, health endpoints |
| **Session/Compaction** | 14 | Tool-use pairing, transcript corruption, thinking blocks, double-compaction |
| **Channel/Platform** | 16 | Discord, Telegram, Slack, Signal -- crashes, typing leaks, delivery |
| **Memory** | 4 | BM25 scoring, FTS indexing, embedding model, flush timing |
| **Config/Env** | 12 | Token drift, cert forwarding, env redaction, rate limiting |
| **Bug/Stability** | 40 | General fixes: model failover, logger binding, surrogate repair |
| **Platform-Specific** | 3 | FIX-A1/A2/A3 -- macOS gateway environment fixes |
| **Disabled** | 1 | #28258 -- stream wrapper crash (safety net in dist-patches.sh) |

Risk levels:
- `low` -- clean `git apply`
- `medium` -- needed exclude-test/changelog strategy
- `high` -- has manual script (custom handling)
- `critical` -- FIX scripts or disabled patches

---

## Cognitive Memory v4

Custom enhancement to OpenClaw's `memory-lancedb` extension. Externalized to `~/.openclaw/extensions/memory-lancedb/` (upgrade-safe).

| Feature | Description |
|---------|-------------|
| **Self-Pruning** | Dormant memories >30 days auto-deleted (preserves corrections, preferences, entities) |
| **Entity Graph** | Cross-agent entity relationships, `ltm entity-graph` / `ltm entity-search` |
| **Mood Detection** | Analyzes user text, injects `<user-mood>` tag into context |
| **Activation Scoring** | ACT-R model: similarity 50% + recency*frequency 35% + importance 15% |
| **Semantic Dedup** | SHA256 exact + vector similarity 0.85 threshold merge |
| **Enforced RAG** | Memory injection on every prompt. Threshold 0.75, top-K 3 |
| **Hybrid Capture** | Heuristic >= 0.5 direct, 0.2-0.5 LLM verify, < 0.2 skip |
| **Decay Lifecycle** | active -> fading -> dormant -> pruned (category-aware decay rates) |

Source: [mahsumaktas/openclaw-extensions](https://github.com/mahsumaktas/openclaw-extensions) (private)

---

## FIX Scripts

Environment-specific fixes for macOS gateway. Not upstream PRs, but solve real observed problems:

| Script | Problem | Fix |
|--------|---------|-----|
| **FIX-A1** | `probeGateway` fails with self-signed cert | Pass `tlsFingerprint` to probe call |
| **FIX-A2** | Carbon `ResilientGatewayPlugin` uncaught exception | Dual-layer: source + carbon node_modules error handler |
| **FIX-A3** | WSS connections reject self-signed certs | Accept self-signed with fingerprint verification |

---

## Automation

| Job | Trigger | What it does |
|-----|---------|--------------|
| **nightly-scan.sh** | Cron 5 AM daily | Scan 500 recent PRs, Treliq score, apply-check, merge tracking, Discord report |
| **post-update-check.sh** | LaunchAgent (package.json change) | Detect upgrade, run patch pipeline, restart gateway |
| **health-monitor.sh** | Post-patch (5min) | Gateway health watch, 3+ crash = auto-rollback |
| **pre-upgrade-check.sh** | Manual (before upgrade) | Conflict analysis, merge detection, safety report |
| **discover-patches.sh** | Manual | GitHub PR scanner for new patch candidates |

---

## Files

```
openclaw-patchkit/
|-- pr-patches.conf               # 119 PR + 3 FIX (single source of truth)
|-- patch-openclaw.sh             # 4-phase orchestrator (--rollback, --status, --dry-run)
|-- rebuild-with-patches.sh       # Phase 1: source rebuild + auto-retirement
|-- dist-patches.sh               # Phase 2: compiled JS patches (5 safety nets)
|-- cognitive-memory-patch.sh     # Phase 3: extension verification + repair
|-- pre-upgrade-check.sh          # Pre-upgrade conflict analysis (NEW)
|-- nightly-scan.sh               # Nightly PR scan + scoring + merge tracking
|-- post-update-check.sh          # Auto-patch on OpenClaw upgrade
|-- health-monitor.sh             # Gateway health + auto-rollback
|-- discover-patches.sh           # GitHub PR discovery
|-- notify.sh                     # Discord notification helper
|-- install-sudoers.sh            # Passwordless sudo setup
|-- retired-patches.log           # Retirement history (auto-populated)
|-- scan-registry.json            # 5,060 scored PRs
|-- scan-report.txt               # Human-readable tier report
|-- manual-patches/               # 63 active scripts
|   |-- <PR_NUM>-<name>.sh       # 59 PR-based manual patches
|   |-- FIX-A{1,2,3}-*.sh       # 3 environment-specific fixes
|   |-- cognitive-memory-backup/  # v3 backup files
|   +-- removed-stability-audit/  # 7 archived scripts
|-- docs/
|   +-- cognitive-memory-specs.md
+-- research/
    |-- scientific-validation.md
    +-- msam-analysis.md
```

---

## Philosophy

Every change must answer 5 questions:

1. Does this solve a **real, observed** problem?
2. Can I **test it in isolation**?
3. Is it **reversible**?
4. What's the **blast radius**?
5. What happens if I **don't** change this?

If any answer is "no" or "unknown" -- skip it, document why.

**Red lines:**
- No touching working subsystems for "improvement"
- No bundled changes -- one PR, one problem
- No changes without a rollback plan
- Verify before assuming
- PR close != removal -- closed PRs stay if the fix is still valuable

---

## Upgrade Policy

- **Stay on current base** until PR merges reduce patch count or a critical fix lands
- v2026.2.25 skipped (0 PRs merged, TS 7.0-dev risk)
- v2026.2.26 adopted (stable, TS ^5.9.3)
- Extensions externalized to `~/.openclaw/extensions/` (survive upgrades)
- `pre-upgrade-check.sh` before any version bump
- `pr-patches.conf` is the single source of truth
- Manual patches are idempotent (safe to re-run)

---

## License

[MIT](LICENSE)
