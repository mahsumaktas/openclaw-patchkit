# OpenClaw Patchkit

Stability-first bug-fix patches for [OpenClaw](https://github.com/openclaw/openclaw). 119 curated patches from 5,300+ scanned PRs, scored with [Treliq](https://github.com/mahsumaktas/treliq) and Sonnet 4.6. Every patch solves a real, observed problem. Nothing speculative, nothing cosmetic.

> **"If it ain't broke, don't fix it."** Working system > theoretically better system.

---

## Disclaimer

**USE AT YOUR OWN RISK.** This patchkit is provided as-is, without warranty of any kind. Applying these patches to your OpenClaw installation is entirely your responsibility. The authors are not liable for any damage, data loss, service disruption, or other issues that may result from using this software.

- These patches are maintained for a specific macOS gateway setup and may not work in your environment.
- Always back up your installation before applying patches.
- Test in a non-production environment first.
- The authors make no guarantees about compatibility with future OpenClaw versions.

This repository contains only tooling scripts, patch metadata, and build automation. It does **not** include OpenClaw source code or patched binaries. [OpenClaw](https://github.com/openclaw/openclaw) is developed by its own maintainers. Patches reference open PRs submitted by various contributors.

---

## Current State

| Metric | Value |
|--------|-------|
| Base version | **v2026.2.26** |
| Active PR patches | **119** |
| FIX scripts | **3** (environment-specific) |
| Manual patch scripts | **63** (59 PR + 3 FIX + 1 cognitive memory) |
| Cognitive Memory | **v3** (entity extraction, enforced RAG) |
| Waves | **14** |
| Scanned PRs | **5,329** |
| Treliq scored | **5,060** |
| Disabled | 1 (#28258 — stream wrapper crash) |
| Last update | 2026-02-27 (Wave 14: +8 patches) |

---

## Philosophy

Every change must answer 5 questions before it touches the codebase:

1. Does this solve a **real, observed** problem?
2. Can I **test it in isolation** before applying?
3. Is it **reversible** if something goes wrong?
4. What's the **blast radius** if it fails?
5. What happens if I **don't** make this change?

If any answer is "no" or "unknown" — skip it, document why.

**Red lines:**
- No touching working subsystems for "improvement"
- No bundled changes — one PR, one problem
- No changes without a rollback plan
- Verify before assuming
- PR close != removal — closed PRs stay if the fix is still valuable

---

## Quick Start

```bash
# Clone
git clone https://github.com/mahsumaktas/openclaw-patchkit.git

# Full pipeline (rebuild + dist patches + extensions + verify)
sudo bash patch-openclaw.sh

# Individual phases
sudo bash patch-openclaw.sh --phase 1    # Source rebuild only
sudo bash patch-openclaw.sh --phase 2    # Dist patches only
sudo bash patch-openclaw.sh --phase 3    # Extension patches only
sudo bash patch-openclaw.sh --status     # Show last run report
sudo bash patch-openclaw.sh --dry-run    # Preview without changes
```

**Requirements:** Node.js >= 22.12.0, pnpm, GitHub CLI (`gh`), macOS (LaunchAgent integration).

---

## Unified Patch Pipeline

`patch-openclaw.sh` orchestrates all patching in 4 phases:

```
Phase 1: Source Rebuild     -> 119 PR diffs + 3 FIX scripts, TypeScript build, dist swap
Phase 2: Dist Patches       -> TLS probe, self-signed cert, LanceDB deps, Cognitive Memory, safety nets
Phase 3: Extension Patches  -> Cognitive Memory v3 (fallback if Phase 2 handled it)
Phase 4: Verification       -> 5 automated checks (entry.js, TLS, cert, memory, version)
```

### 5-Strategy Cascade (Phase 1)

Each PR diff is tried with increasingly relaxed strategies until one succeeds:

| # | Strategy | Description |
|---|----------|-------------|
| 0 | Manual patch | Custom bash/python3 scripts (highest priority) |
| 1 | Clean apply | `git apply` — exact match |
| 2 | Exclude tests | `--exclude '*.test.*'` |
| 3 | Exclude changelog+tests | `--exclude 'CHANGELOG.md'` + tests |
| 4 | 3-way merge | `git apply --3way` |

Manual patches take priority because handcrafted scripts handle context drift, import conflicts, and multi-patch file ordering more reliably than raw diffs.

---

## FIX Scripts (3)

Environment-specific fixes for macOS gateway setups. Not upstream PRs, but solve real observed problems:

| Script | Description |
|--------|-------------|
| **FIX-A1** | Pass `tlsFingerprint` to `probeGateway` for self-signed cert probe |
| **FIX-A2** | Catch `ResilientGatewayPlugin` uncaught exception on `maxAttempts=0` (dual-layer: source + carbon node_modules) |
| **FIX-A3** | Accept self-signed cert for wss:// connections without fingerprint |

---

## PR Patches (119)

Organized in 14 waves. Each wave represents a scan/review cycle.

### Wave 1: Hand-picked Critical Fixes (7)
Model allowlist, agent routing, PID cleanup, session contention, Discord delivery, console timestamps, ACP delta flush.

### Wave 2: Systematic Scan (7)
Config safety, compaction repair, prompt injection prevention, session crash guards, surrogate pair truncation, zero-width Unicode bypass.

### Wave 3: Comprehensive Treliq Scan (16)
2,250 PRs scored. Security (prototype pollution, auth header leaks, cron permissions), stability (fetch timeouts, error handling), memory/session (flush fix, BM25 scoring), gateway/channel (Discord v2, SSE encoding, WebSocket 429).

### Wave 4: Sonnet 4.6 Full Scan (12)
4,051 PRs re-scored. Billing failover, Telegram provider IDs, type array handling, auth rate limiting, LaunchAgent CA certs, pairing recovery hints, config env var preservation, FD exhaustion prevention, usage cost totals, error payload filtering, auto-reply guards, Telegram reaction filtering.

### Wave 5: Tier 1 Batch (3)
Score >= 80 from curated report. TLS exposure warning, hook session context, cron delivery mode.

### Wave 6: Deep Review Batch (9)
Daemon stop fix, echo loop prevention, hook agentId enforcement, session corruption prevention, orphan tool results, cron write drain, BM25 minScore cap, child run finalization, heartbeat transcript preservation.

### Wave 7: High-Risk Manual Patches (3)
`#24840a`: env.vars redaction with `register(sensitive)`. `#24840c`: CLI `--cookie-url` rename. `#25381`: preserve thinking blocks during compaction (selective from 12-file PR).

### Wave 8: Nightly Scan Batch (10)
Pre-auth WS handshake cap, pre-auth frame limit, group chat allowlist, KeepAlive plist fix, graceful drain, OpenAI ingress bind, streaming fetch errors, cron jobId normalization, Discord resume death spiral.

### Wave 9: Targeted Fixes (4)
Undici TLS crash-loop, stale PID kill, media serve allowlist, EXTERNAL_UNTRUSTED_CONTENT leak stripping.

### Wave 10: Analysis Report Batch (5)
Secret detection, network config overrides, allowAgents schema, cross-provider thinking block strip, lone surrogate repair.

### Wave 11: Critical Fixes + Security Hardening (8)
Telegram 401 typing crash, LaunchAgent post-update restart, log rotation, /healthz JSON, spoofed system message neutralization, compaction contextTokens cap, delivery retry cleanup, config unknown key stripping.

### Wave 12: Stability Fixes (4)
Typing indicator leak (4-channel onCleanup), Discord reconnect crash, TLS probe fingerprint, WSS self-signed cert fallback.

### Wave 13: Nightly Scan Batch (21)
Filtered from 41 candidates: 17 closed (not merged), 3 already covered. Discord bot-own event filter, sessions_send fixes (Telegram/Discord/Signal/Slack), orphaned lock cleanup, symlink tar rejection, Discord embed preview ignore, brute-force pairing protection, edit alias normalization, API key masking, embedding model typing fix, model failover on connection-refused, Anthropic stream event retry, JSON.parse guard, Telegram oversized file crash, orphaned tool_result compaction, transcript corruption resilience, Telegram update ID crash replay, polling initialization, model reset keywords.

### Wave 14: Manual Review Batch (8)
Mistral tool call ID sanitization, double-compaction prevention, FTS-only indexing, token drift fix, TLS cert forwarding, empty content death spiral, NaN reserveTokens guard, cron memory leak.

---

## Cognitive Memory v3

Enhancement to OpenClaw's `memory-lancedb` extension. Entity extraction, enforced RAG, and hybrid capture pipeline.

| Feature | Description |
|---------|-------------|
| **Entity Extraction** | Regex NER: person, tech, org, project, location. Turkish + English. |
| **Enforced RAG** | Memory injection on every prompt. Threshold 0.75, top-K 3, entity boost. |
| **Hybrid Capture** | Heuristic score >= 0.5 direct, 0.2-0.5 LLM verify, < 0.2 skip. |
| **Activation Scoring** | ACT-R model: similarity (50%) + recency*frequency (35%) + importance (15%). |
| **Semantic Dedup** | Near-duplicate merge (0.85 threshold) + content hash dedup. |

Auto-migration from v1 and v2 schemas. Research: [`research/`](research/).

---

## Automation

### Nightly Scan (`nightly-scan.sh`)
Runs daily at 5 AM via cron. Fetches up to 500 recently-updated PRs, scores with Treliq + Sonnet 4.6, runs `git apply --check` on high-score PRs, checks if patched PRs merged upstream. Reports to Discord.

### Post-Update Check (`post-update-check.sh`)
LaunchAgent triggered by `package.json` changes. Detects version bumps, runs full patch pipeline, restarts gateway.

### Health Monitor (`health-monitor.sh`)
Checks gateway process, port, Discord/Telegram connections, delivery queue, error logs.

---

## Files

```
openclaw-patchkit/
|-- pr-patches.conf                      # 119 PR patches + 3 FIX (single source of truth)
|-- patch-openclaw.sh                    # Unified 4-phase orchestrator
|-- rebuild-with-patches.sh              # Phase 1: source rebuild (5-strategy cascade)
|-- dist-patches.sh                      # Phase 2: compiled JS patches + cognitive memory
|-- nightly-scan.sh                      # Automated nightly scan + scoring + Discord reports
|-- post-update-check.sh                 # Auto-patch after OpenClaw updates
|-- health-monitor.sh                    # Gateway health checker
|-- discover-patches.sh                  # Scan GitHub for new PRs
|-- notify.sh                            # Discord notification helper
|-- cognitive-memory-patch.sh            # Standalone cognitive memory installer
|-- install-sudoers.sh                   # Passwordless sudo for patch scripts
|-- scan-registry.json                   # 5,060 scored PRs with metadata
|-- scan-report.txt                      # Human-readable tiered PR report
|-- manual-patches/                      # 63 active scripts
|   |-- <PR_NUM>-<name>.sh              # 59 PR-based manual patches
|   |-- FIX-A{1,2,3}-*.sh              # 3 environment-specific fixes
|   |-- cognitive-memory-backup/         # Patched + original memory extension files
|   +-- removed-stability-audit/         # 7 archived scripts
|-- docs/
|   +-- cognitive-memory-specs.md
+-- research/
    |-- scientific-validation.md
    +-- msam-analysis.md
```

---

## Upgrade Policy

- **Stay on current base** until PR merges reduce patch count or a critical fix lands upstream
- v2026.2.25 skipped (0 PRs merged, TS 7.0.0-dev risk)
- v2026.2.26 adopted (stable, TS ^5.9.3, 0 src/ changes from v2026.2.24)
- PR close != removal: closed PRs stay if the fix is still valuable
- Manual patches are idempotent (safe to re-run)
- `pr-patches.conf` is the single source of truth

---

## License

[MIT](LICENSE)
