#!/usr/bin/env bash
# Issue #27474: fix: mask API key snippets in /models and /model status output
#
# Problem: API keys were partially visible (first/last chars shown) in /models
# and /model status output. Even partial key exposure is a security risk.
#
# Fix: Replace tiered masking with simple "****" for all non-empty keys.
# v2026.3.7: model-auth-label.ts was refactored — no longer uses maskApiKey
# directly. It now resolves auth labels via profile store.
# Only mask-api-key.ts needs patching.
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'return "\*\*\*\*"' "$SRC/utils/mask-api-key.ts" 2>/dev/null; then
  echo "    SKIP: #27474 already applied"
  exit 0
fi

# ── mask-api-key.ts ──────────────────────────────────────────────────────
python3 - "$SRC/utils/mask-api-key.ts" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, "r") as f:
    code = f.read()

old = """\
export const maskApiKey = (value: string): string => {
  const trimmed = value.trim();
  if (!trimmed) {
    return "missing";
  }
  if (trimmed.length <= 6) {
    return `${trimmed.slice(0, 1)}...${trimmed.slice(-1)}`;
  }
  if (trimmed.length <= 16) {
    return `${trimmed.slice(0, 2)}...${trimmed.slice(-2)}`;
  }
  return `${trimmed.slice(0, 8)}...${trimmed.slice(-8)}`;
};"""

new = """\
export const maskApiKey = (value: string): string => {
  if (!value.trim()) {
    return "missing";
  }
  return "****";
};"""

if old not in code:
    print("    FAIL: #27474 maskApiKey function body not found in mask-api-key.ts", file=sys.stderr)
    sys.exit(1)

code = code.replace(old, new, 1)

with open(filepath, "w") as f:
    f.write(code)
print("    OK: #27474 mask-api-key.ts patched")

PYEOF

echo "    OK: #27474 fully applied (mask-api-key.ts only; model-auth-label.ts refactored upstream)"
