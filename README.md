# OpenClaw Patchkit v2

**v2026.3.2 -- 124 patches -- 6-strategy pipeline -- 100% apply rate**

Production-tested patch management system for OpenClaw. Provides atomic upgrades, runtime monkey-patches, and symlink-based instant rollback.

## Why Patchkit?

OpenClaw ships as a compiled Node.js application. Out of the box, you get whatever the release includes — bugs, limitations, and all. You wait for the next release and hope your issue is fixed.

Patchkit changes this. It applies community-contributed patches (from unmerged PRs) **on top of** the official release, giving you fixes and improvements weeks or months before they ship upstream.

| | Stock OpenClaw | OpenClaw + Patchkit |
|---|---|---|
| **Bug fixes** | Wait for next release | Apply today from PR |
| **Gateway stability** | Stock error handling | Runtime patches (TLS, Carbon, stream safety) |
| **Upgrades** | Manual npm install, hope nothing breaks | Atomic swap + 60s health probe + auto-rollback |
| **Rollback** | "Did you make a backup?" | `--rollback` (1ms symlink switch) |
| **Patch tracking** | Manual, per-machine | `pr-patches.conf` with categories, risk levels, auto-retirement |
| **New patches** | You find them yourself | Nightly scan scores 500 PRs with Treliq AI, reports to Discord |

**Current state:** 124 active patches + 2 platform fixes on OpenClaw v2026.3.2. Running in production since February 2026.

## Architecture

```
upgrade-openclaw.sh v2026.3.2
|
+-- [1] Pre-flight -- conflict analysis, merge detection
+-- [2] Sandbox Build -- isolated /tmp/ build with 6-strategy patch pipeline
+-- [3] Extension Deps -- LanceDB native binding check
+-- [4] Atomic Swap -- versioned dist + symlink (1ms swap)
+-- [5] Health Probe -- 60s gateway monitoring + auto-rollback
+-- [6] Report -- JSONL log + Discord notification
```

## Quick Start

```bash
# Analyze upgrade without making changes
./upgrade-openclaw.sh v2026.3.2 --dry-run

# Full upgrade
./upgrade-openclaw.sh v2026.3.2

# Instant rollback
./upgrade-openclaw.sh --rollback

# Check status
./upgrade-openclaw.sh --status
```

## Components

### upgrade-openclaw.sh (Main Orchestrator)

Single command replaces the old 3-script pipeline (patch-openclaw.sh + dist-patches.sh + health-monitor.sh).

| Mode | Command |
|------|---------|
| Full upgrade | `upgrade-openclaw.sh v2026.3.2` |
| Dry run | `upgrade-openclaw.sh v2026.3.2 --dry-run` |
| Rollback | `upgrade-openclaw.sh --rollback` |
| Status | `upgrade-openclaw.sh --status` |
| List versions | `upgrade-openclaw.sh --list-versions` |

### Runtime Patches

Node.js `--require` based monkey-patches that replace fragile dist-level sed patching. Loaded at gateway startup via LaunchAgent.

| Patch | Replaces | Purpose |
|-------|----------|---------|
| `loader.js` | -- | Loads all runtime patches, handles failures gracefully |
| `carbon-error-handler.js` | dist-patches Patch 1b | Catches Carbon GatewayPlugin uncaught exceptions |
| `tls-probe-fix.js` | dist-patches Patch 1 | Upgrades ws:// to wss:// when TLS enabled |
| `self-signed-cert.js` | dist-patches Patch 2 | Accepts self-signed certs for local gateway |
| `safety-net-28258.js` | dist-patches Patch 5 | Neutralizes #28258 stream wrapper |
| `thinking-drop-fix.js` | dist-patches Patch 6 | Prevents valid messages from being dropped |

### Symlink-Based Dist Management

Atomic version switching via symlink swap:

```
dist/ -> dist-active -> dist-versions/v2026.3.2-patched/
```

- Swap: 1ms (atomic rename)
- Rollback: 1ms (point symlink to previous version)
- History: Last 3 versions kept

### 6-Strategy Patch Pipeline

Applied in order for each PR patch. Falls through to the next strategy on failure:

1. **Manual script** -- `manual-patches/{pr_num}-*.sh` (most reliable, python3 exact string matching)
2. **Clean apply** -- `git apply`
3. **Exclude tests** -- `git apply --exclude='*.test.*' --exclude='*.e2e.*'` etc.
4. **Exclude changelog+tests** -- Also excludes CHANGELOG.md and docs/*
5. **Fuzz-C1** -- `git apply -C1` with exclusions (reduced context matching)
6. **3-way merge** -- `git apply --3way` (last resort)

### Nightly Scan

Automated PR discovery and scoring (cron 05:00 daily):

- Fetches new/updated PRs from GitHub (max 500, 5 pages, sort:updated-desc)
- Scores with Treliq dual-scoring (CheckEval + TOPSIS) via Sonnet 4.6
- Reports to Discord with per-PR breakdown
- Detects merged PRs and auto-retires them
- Auto-add disabled -- human review required

### pr-patches.conf

Patch registry with categories and risk levels:

```
# SECURITY (14 patches)
12345 | Fix auth bypass [risk:low] [verified:v2026.3.2]

# GATEWAY/DAEMON (19 patches)
23456 | TLS probe fix [risk:medium] [verified:v2026.3.2]
```

9 categories: SECURITY, GATEWAY/DAEMON, SESSION/COMPACTION, CHANNEL/PLATFORM, MEMORY, CONFIG/ENV, BUG/STABILITY, PLATFORM-SPECIFIC, DISABLED.

### CLI (`bin/patchkit`)

```bash
patchkit status            # Show current patch state
patchkit add <PR>          # Add a PR to the registry
patchkit remove <PR>       # Remove a PR from the registry
patchkit upgrade <version> # Run full upgrade pipeline
```

## Stats (v2026.3.2)

```
Strategy                Patches   Share
---------------------------------------
S0  Manual script          65     52%  ================================
S1  Clean apply            40     32%  ====================
S2  Exclude tests          13     11%  =======
S3  Exclude cl+tests        1      1%  =
S4  Fuzz-C1                 5      4%  ===
S5  3-way merge             0      0%
FAIL                        0      0%
---------------------------------------
TOTAL                     124    100%
```

FIX scripts (platform-level, applied separately):
- **FIX-A2** -- Discord reconnect crash handler (dual-layer Carbon error handling)
- **FIX-B1** -- Ollama thinking field compatibility

## Directory Structure

```
openclaw-patchkit/
+-- upgrade-openclaw.sh        # Main upgrade orchestrator
+-- rebuild-with-patches.sh    # Sandbox build engine
+-- nightly-scan.sh            # Automated PR scanner (cron)
+-- pre-upgrade-check.sh       # Conflict analysis (GH Compare API)
+-- notify.sh                  # Discord webhook helper
+-- pr-patches.conf            # Patch registry
+-- bin/                       # CLI entry point
|   +-- patchkit               # Main CLI binary
+-- commands/                  # CLI command modules
|   +-- add.sh
|   +-- remove.sh
|   +-- status.sh
|   +-- upgrade.sh
+-- lib/                       # Shared helper modules
|   +-- common.sh              # Logging, colors, shared utils
|   +-- patch-apply.sh         # 6-strategy apply engine
|   +-- config-migrate.sh      # Config migration helpers
|   +-- extension-guard.sh     # Extension conflict detection
|   +-- builtin-disable.sh     # Built-in extension disabler
|   +-- fix-validate.sh        # FIX script validation
+-- runtime-patches/           # Node.js runtime monkey-patches
|   +-- loader.js
|   +-- carbon-error-handler.js
|   +-- tls-probe-fix.js
|   +-- self-signed-cert.js
|   +-- safety-net-28258.js
|   +-- thinking-drop-fix.js
+-- manual-patches/            # 83 PR-specific patch scripts
|   +-- FIX-A2-*.sh            # Platform fix: Discord reconnect
|   +-- FIX-B1-*.sh            # Platform fix: Ollama thinking
|   +-- {pr_num}-*.sh          # Per-PR manual patches
+-- metadata/                  # Configs and patch metadata
|   +-- patches.yaml           # Structured patch definitions
|   +-- extensions.yaml        # Extension compatibility matrix
|   +-- config-migrations/     # Version-specific config transforms
|   +-- fix-patterns/          # FIX script pattern definitions
+-- analysis/                  # Upgrade reports and analysis
|   +-- v2026.3.2-*.md         # Per-version patch test results
+-- history/                   # Version snapshots
|   +-- snapshots/             # Pre-upgrade state captures
+-- scripts/                   # Utility scripts
|   +-- post-upgrade-cleanup.sh
+-- docs/                      # Internal documentation
|   +-- plans/                 # Architecture and design docs
+-- archive/
|   +-- v1-replaced/           # Archived v1 scripts
+-- retired-patches.log        # Tracking of retired PRs
```

## Upgrade History

| Version | Date | Notes |
|---------|------|-------|
| v2026.2.24 | 2026-02-24 | Initial patchkit deployment |
| v2026.2.26 | 2026-02-27 | 118 patches, 3 FIX scripts, 5-strategy pipeline |
| v2026.3.1 | 2026-03-02 | 101 patches (13 retired upstream), config split, built-in extension conflict resolution |
| v2026.3.2 | 2026-03-03 | 124 patches, 2 FIX scripts, 6-strategy pipeline (added fuzz-C1), 20 retired PRs total |

Retired PRs per version:
- **v2026.3.1**: 7 merged upstream + 7 dist-verified = 14 retired
- **v2026.3.2**: 6 additional retirements

## Requirements

- Bash 4.0+
- Node.js 22+ (with --require support)
- pnpm
- Python 3 (for manual patch scripts)
- GitHub CLI (`gh`)
- macOS (LaunchAgent based)
