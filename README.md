# OpenClaw Patchkit v2

Production-tested patch management system for OpenClaw. Provides atomic upgrades, runtime monkey-patches, and symlink-based instant rollback.

## Architecture

```
upgrade-openclaw.sh v2026.2.27
│
├── [1] Pre-flight — conflict analysis, merge detection
├── [2] Sandbox Build — isolated /tmp/ build with 5-strategy patch pipeline
├── [3] Extension Deps — LanceDB native binding check
├── [4] Atomic Swap — versioned dist + symlink (1ms swap)
├── [5] Health Probe — 60s gateway monitoring + auto-rollback
└── [6] Report — JSONL log + Discord notification
```

## Quick Start

```bash
# Analyze upgrade without making changes
./upgrade-openclaw.sh v2026.2.27 --dry-run

# Full upgrade
./upgrade-openclaw.sh v2026.2.27

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
| Full upgrade | `upgrade-openclaw.sh v2026.2.27` |
| Dry run | `upgrade-openclaw.sh v2026.2.27 --dry-run` |
| Rollback | `upgrade-openclaw.sh --rollback` |
| Status | `upgrade-openclaw.sh --status` |
| List versions | `upgrade-openclaw.sh --list-versions` |

### Runtime Patches
Node.js `--require` based monkey-patches that replace fragile dist-level sed patching. Loaded at gateway startup via LaunchAgent.

| Patch | Replaces | Purpose |
|-------|----------|---------|
| `loader.js` | — | Loads all runtime patches, handles failures gracefully |
| `carbon-error-handler.js` | dist-patches Patch 1b | Catches Carbon GatewayPlugin uncaught exceptions |
| `tls-probe-fix.js` | dist-patches Patch 1 | Upgrades ws:// to wss:// when TLS enabled |
| `self-signed-cert.js` | dist-patches Patch 2 | Accepts self-signed certs for local gateway |
| `safety-net-28258.js` | dist-patches Patch 5 | Neutralizes #28258 stream wrapper |
| `thinking-drop-fix.js` | dist-patches Patch 6 | Prevents valid messages from being dropped |

### Symlink-Based Dist Management
Atomic version switching via symlink swap:

```
dist/ → dist-active → dist-versions/v2026.2.27-patched/
```

- Swap: 1ms (atomic rename)
- Rollback: 1ms (point symlink to previous version)
- History: Last 3 versions kept

### 5-Strategy Patch Pipeline
Applied in order for each PR patch:

1. **Manual script** — `manual-patches/{pr_num}-*.sh` (most reliable)
2. **Clean apply** — `git apply`
3. **Exclude tests** — `git apply --exclude='*.test.*'`
4. **Exclude changelog+tests** — Also excludes CHANGELOG.md
5. **3-way merge** — `git apply --3way`

### Nightly Scan
Automated PR discovery and scoring (cron 05:00 daily):

- Fetches new/updated PRs from GitHub (max 500)
- Scores with Treliq + Sonnet 4.6
- Auto-adds stability PRs (score >= 85) to conf — NO live build
- Reports to Discord
- Detects merged PRs and retires them

### pr-patches.conf
Patch registry with categories and risk levels:

```
# SECURITY (14 patches)
12345 | Fix auth bypass [risk:low] [verified:v2026.2.26]

# GATEWAY/DAEMON (19 patches)
23456 | TLS probe fix [risk:medium] [verified:v2026.2.26]
```

9 categories: SECURITY, GATEWAY/DAEMON, SESSION/COMPACTION, CHANNEL/PLATFORM, MEMORY, CONFIG/ENV, BUG/STABILITY, PLATFORM-SPECIFIC, DISABLED.

## Directory Structure

```
├── upgrade-openclaw.sh        # Main upgrade orchestrator
├── rebuild-with-patches.sh    # Sandbox build engine
├── migrate-to-symlink.sh      # One-time dist → symlink migration
├── nightly-scan.sh            # Automated PR scanner (cron)
├── notify.sh                  # Discord webhook helper
├── pr-patches.conf            # Patch registry
├── runtime-patches/           # Node.js runtime monkey-patches
│   ├── loader.js
│   ├── carbon-error-handler.js
│   ├── tls-probe-fix.js
│   ├── self-signed-cert.js
│   ├── safety-net-28258.js
│   └── thinking-drop-fix.js
├── manual-patches/            # 60+ PR-specific patch scripts
│   ├── FIX-A1-*.sh           # Platform fixes
│   ├── FIX-A2-*.sh
│   ├── FIX-A3-*.sh
│   └── {pr_num}-*.sh         # Per-PR manual patches
└── archive/
    └── v1-replaced/           # Archived v1 scripts
```

## Migration from v1

One-time migration required (run before first v2 upgrade):

```bash
# 1. Stop gateway
launchctl bootout gui/$(id -u)/ai.openclaw.gateway

# 2. Run migration
sudo bash migrate-to-symlink.sh

# 3. Update LaunchAgent plist (add --require for runtime patches)
# 4. Reload gateway
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist
```

## What Changed (v1 → v2)

| Component | v1 | v2 |
|-----------|----|----|
| Orchestrator | `patch-openclaw.sh` (4 phases) | `upgrade-openclaw.sh` (6 phases) |
| Dist patches | `dist-patches.sh` (sed/python on compiled JS) | `runtime-patches/` (Node.js --require) |
| Dist swap | `find -delete + cp` (non-atomic, sudo) | Symlink swap (atomic, 1ms) |
| Rollback | Manual backup restore | `--rollback` (1ms symlink switch) |
| Health check | Separate `health-monitor.sh` | Integrated in upgrade pipeline |
| Pre-upgrade | Separate `pre-upgrade-check.sh` | `--dry-run` mode |
| Nightly scan | Auto-add + live build | Auto-add + sandbox test (no live build) |
| Cognitive memory | Patch 4 (dead code) | Removed (v8.1 self-contained) |

## Requirements

- Bash 4.0+
- Node.js 22+ (with --require support)
- pnpm
- GitHub CLI (`gh`)
- macOS (LaunchAgent based)
