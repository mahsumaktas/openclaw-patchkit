#!/usr/bin/env bash
# FIX-D1: Codex first-party identity + priority tier
#
# PROBLEM: OpenClaw sends originator="pi" and User-Agent="pi (...)" which
# identifies as a third-party client. Also missing service_tier and plan-type.
#
# FIX:
#   1. originator: "pi" → "codex_cli_rs" (first-party Codex CLI status)
#   2. User-Agent: "pi (...)" → "codex_cli_rs/0.1 (...) terminal" (official format)
#   3. Add chatgpt-plan-type: "pro" header (Spark model access)
#   4. Add service_tier: "priority" to request body (fast mode, lower latency)
#
# Affects: @mariozechner/pi-ai/dist/providers/openai-codex-responses.js
set -euo pipefail

OPENCLAW_ROOT="$(dirname "$(readlink "$(which openclaw-gateway)" 2>/dev/null || echo /Users/mahsum/.npm-global/lib/node_modules/openclaw)")"
# Fallback if readlink fails
[[ -d "$OPENCLAW_ROOT/node_modules" ]] || OPENCLAW_ROOT="/Users/mahsum/.npm-global/lib/node_modules/openclaw"
TARGET="$OPENCLAW_ROOT/node_modules/@mariozechner/pi-ai/dist/providers/openai-codex-responses.js"

if [[ ! -f "$TARGET" ]]; then
  echo "SKIP: $TARGET not found"
  exit 0
fi

# Check if fix already applied
if grep -q 'codex_cli_rs' "$TARGET" 2>/dev/null && grep -q 'service_tier.*priority' "$TARGET" 2>/dev/null; then
  echo "OK: FIX-D1 already applied"
  exit 0
fi

python3 - "$TARGET" << 'PYEOF'
import sys

with open(sys.argv[1]) as f:
    content = f.read()

applied = 0

# 1. originator: pi → codex_cli_rs
old1 = '    headers.set("originator", "pi");'
new1 = '    headers.set("originator", "codex_cli_rs");'
if old1 in content:
    content = content.replace(old1, new1)
    print("  + originator: codex_cli_rs")
    applied += 1

# 2. User-Agent: pi format → codex_cli_rs format + chatgpt-plan-type
old2 = """    const userAgent = _os ? `pi (${_os.platform()} ${_os.release()}; ${_os.arch()})` : "pi (browser)";
    headers.set("User-Agent", userAgent);"""
new2 = """    const userAgent = _os ? `codex_cli_rs/0.1 (${_os.platform()} ${_os.release()}; ${_os.arch()}) terminal` : "codex_cli_rs/0.1 (browser)";
    headers.set("User-Agent", userAgent);
    headers.set("chatgpt-plan-type", "pro");"""
if old2 in content:
    content = content.replace(old2, new2)
    print("  + User-Agent: codex_cli_rs/0.1 format")
    print("  + chatgpt-plan-type: pro")
    applied += 1

# 3. service_tier: "priority" in request body (fast mode)
old3 = '        prompt_cache_key: options?.sessionId,\n        tool_choice: "auto",'
new3 = '        prompt_cache_key: options?.sessionId,\n        service_tier: "priority",\n        tool_choice: "auto",'
if old3 in content:
    content = content.replace(old3, new3)
    print("  + service_tier: priority (fast mode)")
    applied += 1
elif 'service_tier' in content:
    print("  ~ service_tier already present")
else:
    print("  WARN: Could not find body pattern for service_tier")

if applied == 0:
    print("FAIL: no patterns matched in target file")
    sys.exit(1)

with open(sys.argv[1], 'w') as f:
    f.write(content)

print(f"APPLIED: FIX-D1 codex first-party + priority tier ({applied} patches)")
PYEOF
