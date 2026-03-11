#!/usr/bin/env bash
# PR #26282 — fix(telegram): reject oversized files before download
# 4 files: telegram/bot/delivery.resolve-media.ts, telegram/bot-handlers.ts,
#          media/store.ts, media/fetch.ts (tests skipped)
#
# v2026.3.8 status: FULLY APPLIED in base (via different file split)
#   - MediaFetchError class with "max_bytes" code: present in media/fetch.ts
#   - isMediaSizeLimitError checks MediaFetchError: present in bot-handlers.ts
#   Note: v2026.3.8 split delivery.ts into delivery.resolve-media.ts
set -euo pipefail
SRC="${1:-.}/src"

HANDLERS="$SRC/telegram/bot-handlers.ts"
FETCH="$SRC/media/fetch.ts"

# ── Idempotency: check for the core fix markers ──
FOUND=0

if grep -q 'isMediaSizeLimitError' "$HANDLERS" 2>/dev/null; then
  FOUND=$((FOUND + 1))
fi

if grep -q 'class MediaFetchError' "$FETCH" 2>/dev/null; then
  FOUND=$((FOUND + 1))
fi

if grep -q 'max_bytes' "$FETCH" 2>/dev/null; then
  FOUND=$((FOUND + 1))
fi

if [ "$FOUND" -ge 2 ]; then
  echo "    SKIP: #26282 already applied (v2026.3.8 base, $FOUND/3 markers found)"
  exit 0
fi

echo "    FAIL: #26282 expected to be in v2026.3.8 base but only $FOUND/3 markers found"
exit 1
