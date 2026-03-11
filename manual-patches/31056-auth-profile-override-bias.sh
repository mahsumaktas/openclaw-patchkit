#!/usr/bin/env bash
# PR #31056 — fix: auto auth profile override should not bias profile ordering
# 3 files: auth-profiles/session-override.ts, pi-embedded-runner/run.ts, (test skipped)
#
# v2026.3.8 status: FULLY APPLIED in base
#   - source === "auto" check with pickFirstAvailable: present in session-override.ts
#   - authProfileIdSource === "user" guard: present in run.ts
set -euo pipefail
SRC="${1:-.}/src"

OVERRIDE="$SRC/agents/auth-profiles/session-override.ts"
RUN="$SRC/agents/pi-embedded-runner/run.ts"

# ── Idempotency: check for actual v2026.3.8 markers ──
FOUND=0

if grep -q 'authProfileOverrideSource.*!==.*"auto"' "$OVERRIDE" 2>/dev/null; then
  FOUND=$((FOUND + 1))
fi

if grep -q 'authProfileIdSource === "user"' "$RUN" 2>/dev/null; then
  FOUND=$((FOUND + 1))
fi

if [ "$FOUND" -ge 2 ]; then
  echo "    SKIP: #31056 already applied (v2026.3.8 base, $FOUND/2 markers found)"
  exit 0
fi

echo "    FAIL: #31056 expected to be in v2026.3.8 base but only $FOUND/2 markers found"
exit 1
