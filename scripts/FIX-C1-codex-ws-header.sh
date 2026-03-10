#!/usr/bin/env bash
# FIX-C1: Fix duplicate OpenAI-Beta header in Codex WebSocket connection
#
# PROBLEM: buildHeaders() sets "OpenAI-Beta" = "responses=experimental" on
# a Headers object. headersToRecord() converts this to lowercase "openai-beta".
# connectWebSocket() then adds wsHeaders["OpenAI-Beta"] = "responses_websockets=..."
# with mixed case. When undici creates new Headers(wsHeaders), both keys merge:
#   "responses=experimental, responses_websockets=2026-02-06"
# ChatGPT's backend receives the wrong beta header and closes the WebSocket with 1011.
#
# FIX: Delete the lowercase "openai-beta" key before setting the WebSocket-specific value.
#
# Affects: @mariozechner/pi-ai/dist/providers/openai-codex-responses.js
set -euo pipefail

OPENCLAW_ROOT="$(dirname "$(readlink "$(which openclaw-gateway)")")"
TARGET="$OPENCLAW_ROOT/node_modules/@mariozechner/pi-ai/dist/providers/openai-codex-responses.js"

if [[ ! -f "$TARGET" ]]; then
  echo "SKIP: $TARGET not found"
  exit 0
fi

# Check if fix already applied
if grep -q 'delete wsHeaders\["openai-beta"\]' "$TARGET" 2>/dev/null; then
  echo "OK: FIX-C1 already applied"
  exit 0
fi

# Apply fix: add delete before the OpenAI-Beta assignment in connectWebSocket
python3 - "$TARGET" << 'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

old = '    const wsHeaders = headersToRecord(headers);\n    wsHeaders["OpenAI-Beta"] = OPENAI_BETA_RESPONSES_WEBSOCKETS;'
new = '''    const wsHeaders = headersToRecord(headers);
    // Remove any existing openai-beta key (lowercase from Headers normalization)
    // to avoid duplicate header values when setting the WebSocket-specific value
    delete wsHeaders["openai-beta"];
    wsHeaders["OpenAI-Beta"] = OPENAI_BETA_RESPONSES_WEBSOCKETS;'''

if old not in content:
    print("FAIL: pattern not found in target file")
    sys.exit(1)

content = content.replace(old, new)
with open(sys.argv[1], 'w') as f:
    f.write(content)

print("APPLIED: FIX-C1 codex-ws-header fix")
PYEOF
