# OpenClaw Patchkit

Curated patches for [OpenClaw](https://github.com/anthropics/claude-code) from 4300+ open PRs — scored, filtered, and tested against the latest release.

## Stats

| Metric | Count |
|--------|-------|
| PRs scanned | 4300+ |
| PRs scored (treliq) | 2250 |
| Patches selected | 56 |
| Manual patches | 5 |
| Waves | 3 |
| Base version | v2026.2.22 |

## How to Use

```bash
# 1. Clone the patchkit
git clone https://github.com/mahsumaktas/openclaw-patchkit.git
cd openclaw-patchkit

# 2. Make sure OpenClaw source is available (default: ../claude-code)
# 3. Run the rebuild script
./rebuild-with-patches.sh
```

The rebuild script will:
- Apply all patches from `pr-patches.conf` (git apply + manual patches)
- Skip patches that fail to apply cleanly (logged to stderr)
- Build the patched version

## Patch Categories

Patches are organized in 3 waves:

### Wave 1 — Original patches (12)
Hand-picked critical fixes: model allowlist, agent routing, PID cleanup, session contention, security hardening.

### Wave 2 — Full scan results (12)
Systematic scan of all open PRs. Includes config safety, compaction repair, prompt injection prevention, session crash guards.

### Wave 3 — Comprehensive scan (32)
2250 PRs scored with treliq. Covers security (prototype pollution, auth header leaks, cron permissions), stability (fetch timeouts, heartbeat dedup, memory leaks), and correctness (surrogate pairs, Unicode bypass, model schema).

## Patch Application Methods

| Method | Count | Description |
|--------|-------|-------------|
| `git apply` (clean) | 28 | Apply directly, no conflicts |
| `git apply --exclude tests` | 10 | Apply excluding test files |
| `git apply --exclude changelog` | 2 | Apply excluding changelog |
| Manual patch scripts | 5 | Complex patches in `manual-patches/` |
| Commented out | 1 | Incompatible with base version |

## Files

| File | Purpose |
|------|---------|
| `pr-patches.conf` | Master list of 56 patches with PR numbers and descriptions |
| `rebuild-with-patches.sh` | Main build script — applies patches and rebuilds |
| `discover-patches.sh` | Scans GitHub for new mergeable PRs |
| `nightly-scan.sh` | Automated nightly scan for new patch candidates |
| `scan-registry.json` | Full scan results with scores and metadata |
| `manual-patches/` | Shell scripts for patches that need manual application |

## Nightly Automation

`nightly-scan.sh` runs on a schedule to:
1. Fetch newly opened/updated PRs from the OpenClaw repo
2. Score each PR using treliq (relevance, risk, merge-readiness)
3. Test application against the current base version
4. Update `scan-registry.json` with results
5. Flag high-scoring candidates for manual review

Run it manually:
```bash
./nightly-scan.sh
```

Or set up a cron job:
```bash
# Every night at 3am
0 3 * * * /path/to/openclaw-patchkit/nightly-scan.sh >> /tmp/patchkit-scan.log 2>&1
```

## Disclaimer

This repository contains only tooling scripts, patch metadata, and build automation.
It does **not** include OpenClaw source code or patched binaries.
[OpenClaw](https://github.com/anthropics/claude-code) is developed by Anthropic and licensed under the Apache License 2.0.

## License

[MIT](LICENSE)
