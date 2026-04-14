#!/usr/bin/env bash
# FIX-D1: Skip startup warmup for codex/openai-codex providers
#
# Issue: prewarmConfiguredPrimaryModel() runs BEFORE the codex plugin's
# OAuth handshake registers the model. isCliProvider("codex") returns
# false during this startup race because:
#   1. Runtime registry not yet populated
#   2. Codex plugin manifest lacks setupCliBackends declaration
#   3. User config cliBackends is empty
# Result: "startup model warmup failed for codex/gpt-5.4: Unknown model"
# logged on EVERY restart. Cosmetic (runtime works via fallback chain),
# but spams gateway.err.log.
#
# Fix: Add explicit early return for codex/openai-codex providers in
# prewarmConfiguredPrimaryModel. Warmup is only a static sanity check;
# skipping it has zero runtime impact — codex model resolution always
# happens dynamically after OAuth.
#
# Risk: low. Localized 1-line addition, only affects startup warmup path.
#
# Verified against: v2026.4.12
set -euo pipefail
SRC="${1:-.}/src"
FILE="$SRC/gateway/server-startup-post-attach.ts"

[ -f "$FILE" ] || { echo "    SKIP: FIX-D1 — target file not found ($FILE)"; exit 0; }

if grep -q 'if (provider === "codex" || provider === "openai-codex") return;' "$FILE"; then
  echo "    SKIP: FIX-D1 codex warmup race already patched"
  exit 0
fi

if ! grep -q "if (isCliProvider(provider, params.cfg)) return;" "$FILE"; then
  echo "    WARN: FIX-D1 — anchor 'isCliProvider' not found, skipping"
  exit 0
fi

# Insert the early return directly after the isCliProvider check line
awk '
  /if \(isCliProvider\(provider, params\.cfg\)\) return;/ {
    print
    print "\tif (provider === \"codex\" || provider === \"openai-codex\") return;"
    next
  }
  { print }
' "$FILE" > "${FILE}.tmp"
mv "${FILE}.tmp" "$FILE"

echo "    OK: FIX-D1 codex warmup race — skip codex/openai-codex at startup warmup"
exit 0
