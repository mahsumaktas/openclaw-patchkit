#!/usr/bin/env bash
# FIX-B1: fix(ollama): handle Qwen thinking field + disable thinking mode
#
# Problem: Qwen 3.5 models put all output in `message.thinking` field,
# not `message.content` or `message.reasoning`. OpenClaw only checks
# content and reasoning, so Ollama Qwen responses appear empty.
#
# Fix:
#   1. Add `think: false` to Ollama request body (disables thinking mode entirely)
#   2. Add `message.thinking` fallback in stream accumulator (safety net)
#
# Compatibility:
#   v2026.3.1: model-selection-BcQumkju.js (single file)
#   v2026.3.2: model-selection-{CjMYMtR0,Zb7eBzSY,ikt2OC4j}.js (multiple files)
#   Uses glob pattern — no hardcoded hash, works with any version.
set -euo pipefail

DIST="${1:-/opt/homebrew/lib/node_modules/openclaw/dist}"

# ── Find all model-selection chunk files ─────────────────────────────────────
shopt -s nullglob
FILES=("$DIST"/model-selection-*.js)
shopt -u nullglob

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "    ERROR: No model-selection-*.js files found in $DIST"
  exit 1
fi

echo "    Found ${#FILES[@]} model-selection file(s)"

PATCHED=()
SKIPPED=()
FAILED=()

for TARGET in "${FILES[@]}"; do
  BASENAME="$(basename "$TARGET")"

  # ── Idempotency check ───────────────────────────────────────────────────
  if grep -q 'message?.thinking' "$TARGET" 2>/dev/null; then
    echo "    SKIP: $BASENAME (already applied)"
    SKIPPED+=("$BASENAME")
    continue
  fi

  # ── Check if file contains Ollama-related code ─────────────────────────
  if ! grep -q 'ollamaOptions\|ollama' "$TARGET" 2>/dev/null; then
    echo "    SKIP: $BASENAME (no Ollama code)"
    SKIPPED+=("$BASENAME")
    continue
  fi

  # ── Backup (per-file) ──────────────────────────────────────────────────
  cp "$TARGET" "$TARGET.pre-B1.bak"

  # ── Apply patches ──────────────────────────────────────────────────────
  RESULT=$(python3 - "$TARGET" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

applied = 0

# Patch 1: Add think:false to body (disable Qwen thinking mode)
old = 'options: ollamaOptions\n\t\t\t\t};'
new = 'options: ollamaOptions,\n\t\t\t\t\tthink: false\n\t\t\t\t};'
if old in content:
    content = content.replace(old, new)
    print("      + think:false in Ollama request body")
    applied += 1
else:
    print("      WARN: Could not find body pattern for think:false")

# Patch 2: Add message.thinking fallback in stream accumulator
old2 = 'else if (chunk.message?.reasoning) accumulatedContent += chunk.message.reasoning;'
new2 = ('else if (chunk.message?.reasoning) accumulatedContent += chunk.message.reasoning;\n'
        '\t\t\t\t\telse if (chunk.message?.thinking) accumulatedContent += chunk.message.thinking;')
if old2 in content:
    content = content.replace(old2, new2)
    print("      + message.thinking fallback in stream accumulator")
    applied += 1
else:
    print("      WARN: Could not find reasoning pattern for thinking fallback")

with open(path, 'w') as f:
    f.write(content)

print(f"__APPLIED:{applied}")
PYEOF
  )

  echo "$RESULT" | grep -v '^__APPLIED:'

  APPLY_COUNT=$(echo "$RESULT" | grep '^__APPLIED:' | cut -d: -f2)
  if [[ "$APPLY_COUNT" -gt 0 ]]; then
    PATCHED+=("$BASENAME")
  else
    FAILED+=("$BASENAME")
    # Restore backup if nothing was applied
    mv "$TARGET.pre-B1.bak" "$TARGET"
  fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "    ── FIX-B1 Summary ──"
echo "    Patched: ${#PATCHED[@]}  Skipped: ${#SKIPPED[@]}  Failed: ${#FAILED[@]}"
[[ ${#PATCHED[@]} -gt 0 ]] && echo "    Patched files: ${PATCHED[*]}"
[[ ${#SKIPPED[@]} -gt 0 ]] && echo "    Skipped files: ${SKIPPED[*]}"
[[ ${#FAILED[@]} -gt 0 ]]  && echo "    Failed files:  ${FAILED[*]}"

if [[ ${#PATCHED[@]} -eq 0 && ${#SKIPPED[@]} -eq 0 ]]; then
  echo "    ERROR: No files were patched or previously patched"
  exit 1
fi
