#!/usr/bin/env bash
# Issue #27474: fix: mask API key snippets in /models and /model status output
#
# Problem: API keys were partially visible (first/last chars shown) in /models
# and /model status output. Even partial key exposure is a security risk.
#
# Fix: Replace tiered masking with simple "****" for all non-empty keys.
# model-auth-label.ts already delegates to maskApiKey in v2026.2.26, so
# changing maskApiKey fixes both locations.
#
# Changes:
#   1. src/utils/mask-api-key.ts — return "****" for all non-empty values
#   2. src/agents/model-auth-label.ts — simplify formatApiKeySnippet
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'return "\*\*\*\*"' "$SRC/utils/mask-api-key.ts" 2>/dev/null; then
  echo "    SKIP: #27474 already applied"
  exit 0
fi

# ── 1. mask-api-key.ts ─────────────────────────────────────────────────────
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

# ── 2. model-auth-label.ts — simplify formatApiKeySnippet ─────────────────
python3 - "$SRC/agents/model-auth-label.ts" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, "r") as f:
    code = f.read()

old = """\
function formatApiKeySnippet(apiKey: string): string {
  const compact = apiKey.replace(/\\s+/g, "");
  if (!compact) {
    return "unknown";
  }
  return maskApiKey(compact);
}"""

new = """\
function formatApiKeySnippet(apiKey: string): string {
  if (!apiKey.replace(/\\s+/g, "")) {
    return "unknown";
  }
  return "****";
}"""

if old not in code:
    print("    FAIL: #27474 formatApiKeySnippet not found in model-auth-label.ts", file=sys.stderr)
    sys.exit(1)

code = code.replace(old, new, 1)

with open(filepath, "w") as f:
    f.write(code)
print("    OK: #27474 model-auth-label.ts patched")

PYEOF

echo "    OK: #27474 fully applied"
