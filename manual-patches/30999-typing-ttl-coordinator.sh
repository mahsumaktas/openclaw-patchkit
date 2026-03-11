#!/usr/bin/env bash
# PR #30999 — fix: typing TTL coordinator for stuck typing indicators
# 5 files: channels/typing.ts (edit), channels/typing-lifecycle.ts (edit),
#          channels/typing-start-guard.ts (new), channels/typing.test.ts,
#          channels/typing-start-guard.test.ts (tests skipped)
#
# v2026.3.8 status: FULLY APPLIED in base
#   - maxDurationMs + ttlTimer in typing.ts: present
#   - typing-lifecycle.ts keepalive loop: present
#   - typing-start-guard.ts guard module: present
set -euo pipefail
SRC="${1:-.}/src"

TYPING="$SRC/channels/typing.ts"
GUARD="$SRC/channels/typing-start-guard.ts"

# ── Idempotency: check for actual v2026.3.8 markers ──
FOUND=0

if grep -q 'maxDurationMs' "$TYPING" 2>/dev/null; then
  FOUND=$((FOUND + 1))
fi

if grep -q 'ttlTimer' "$TYPING" 2>/dev/null; then
  FOUND=$((FOUND + 1))
fi

if [ -f "$GUARD" ]; then
  FOUND=$((FOUND + 1))
fi

if [ "$FOUND" -ge 2 ]; then
  echo "    SKIP: #30999 already applied (v2026.3.8 base, $FOUND/3 markers found)"
  exit 0
fi

echo "    FAIL: #30999 expected to be in v2026.3.8 base but only $FOUND/3 markers found"
exit 1
