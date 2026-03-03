#!/usr/bin/env bash
set -euo pipefail
cd "$1"

# PR #28514 — Mistral strict9 tool call ID sanitization for proxy providers
# When Mistral models are used via proxy providers (NVIDIA NIM, OpenRouter, etc.)
# the openai-completions API is used but Mistral still enforces 9-char alphanumeric
# tool call IDs. Without this fix, sanitization is suppressed and upstream returns 400.

FILE="src/agents/transcript-policy.ts"

if [[ ! -f "$FILE" ]]; then
  echo "SKIP #28514: $FILE not found"
  exit 0
fi

# Idempotency: check if forceMistralSanitize is already present
if grep -q 'forceMistralSanitize' "$FILE" 2>/dev/null; then
  echo "SKIP #28514: already patched (forceMistralSanitize found)"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# --- PART 1: Add the forceMistralSanitize constant before the return block ---
# Find the sanitizeThoughtSignatures line and inject after it

old_block = '''  const sanitizeThoughtSignatures =
    isOpenRouterGemini || isGoogle ? { allowBase64Only: true, includeCamelCase: true } : undefined;

  return {'''

new_block = '''  const sanitizeThoughtSignatures =
    isOpenRouterGemini || isGoogle ? { allowBase64Only: true, includeCamelCase: true } : undefined;

  // Mistral models require strict9 tool call ID sanitization regardless of the API
  // transport. Proxy providers like NVIDIA NIM or OpenRouter use openai-completions
  // but forward requests directly to Mistral, which enforces the 9-char alphanumeric
  // constraint. Without this override, `!isOpenAi` suppresses sanitization and the
  // upstream rejects every tool call with a 400 (see #28492).
  const forceMistralSanitize = isMistral && !isOpenAiProvider(provider);

  return {'''

if old_block not in content:
    print(f"FAIL #28514: could not find sanitizeThoughtSignatures + return block in {filepath}")
    sys.exit(1)

content = content.replace(old_block, new_block, 1)

# --- PART 2: Replace sanitizeMode line ---
# v2026.3.2 has:
#   sanitizeMode: isOpenAi ? "images-only" : needsNonImageSanitize ? "full" : "images-only",
old_sanitize_mode = '    sanitizeMode: isOpenAi ? "images-only" : needsNonImageSanitize ? "full" : "images-only",'

new_sanitize_mode = '''    sanitizeMode: forceMistralSanitize
      ? "full"
      : isOpenAi
        ? "images-only"
        : needsNonImageSanitize
          ? "full"
          : "images-only",'''

if old_sanitize_mode not in content:
    print(f"FAIL #28514: could not find sanitizeMode line in {filepath}")
    sys.exit(1)

content = content.replace(old_sanitize_mode, new_sanitize_mode, 1)

# --- PART 3: Replace sanitizeToolCallIds line ---
# v2026.3.2 has:
#   sanitizeToolCallIds:
#     (!isOpenAi && sanitizeToolCallIds) || requiresOpenAiCompatibleToolIdSanitization,
old_tool_ids = '''    sanitizeToolCallIds:
      (!isOpenAi && sanitizeToolCallIds) || requiresOpenAiCompatibleToolIdSanitization,'''

new_tool_ids = '''    sanitizeToolCallIds:
      forceMistralSanitize || (!isOpenAi && sanitizeToolCallIds) || requiresOpenAiCompatibleToolIdSanitization,'''

if old_tool_ids not in content:
    print(f"FAIL #28514: could not find sanitizeToolCallIds block in {filepath}")
    sys.exit(1)

content = content.replace(old_tool_ids, new_tool_ids, 1)

with open(filepath, 'w') as f:
    f.write(content)

print("OK #28514: added forceMistralSanitize for proxy providers")
PYEOF
