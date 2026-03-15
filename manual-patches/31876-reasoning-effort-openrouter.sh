#!/usr/bin/env bash
# PR #31876 — don't auto-promote reasoning_effort for openrouter/auto; add ThinkLevel "auto"
#
# Changes:
# 1. Add "auto" to ThinkLevel union in model-selection.ts and thinking.ts
# 2. Add PASSTHROUGH_ROUTER_MODELS set and guard in resolveThinkingDefaultForModel
# 3. Accept "auto" in perModelThinking check in resolveThinkingDefault
# 4. normalizeThinkLevel: separate "auto" from "adaptive" — "auto" now returns "auto"
# 5. mapThinkingLevel: "auto" maps to "off" (let provider decide)
# 6. OpenRouter extra-params: "auto" treated like "off" — skip reasoning injection
# 7. Add "auto" to zod schema for thinkingDefault
#
# v1: Written for v2026.3.13
set -euo pipefail
SRC="${1:-.}/src"

# ── Idempotency ──
if grep -q 'PASSTHROUGH_ROUTER_MODELS' "$SRC/agents/model-selection.ts" 2>/dev/null; then
  echo "    SKIP: #31876 already applied"
  exit 0
fi

CHANGES=0

# ─── 1) model-selection.ts: Add "auto" to ThinkLevel + PASSTHROUGH set + guards ───
FILE="$SRC/agents/model-selection.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changes = 0

# 1a) Add "auto" to ThinkLevel union
old_type = 'export type ThinkLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "adaptive";'
new_type = '''export type ThinkLevel =
  | "off"
  | "minimal"
  | "low"
  | "medium"
  | "high"
  | "xhigh"
  | "adaptive"
  | "auto";'''
if old_type in content:
    content = content.replace(old_type, new_type, 1)
    changes += 1
else:
    print("    FAIL: #31876 ThinkLevel union not found in model-selection.ts", file=sys.stderr)
    sys.exit(1)

# 1b) Add PASSTHROUGH_ROUTER_MODELS before resolveThinkingDefault
anchor = 'export function resolveThinkingDefault(params: {'
if anchor not in content:
    print("    FAIL: #31876 resolveThinkingDefault not found", file=sys.stderr)
    sys.exit(1)

passthrough_block = '''/**
 * Pass-through routing models that don't perform reasoning themselves — they
 * forward the request to a downstream model chosen at runtime.  We must NOT
 * auto-promote thinking for these: the downstream model decides its own
 * reasoning budget, and forcing reasoning_effort on the router causes it to
 * pick reasoning-capable models even for trivial queries.
 *
 * When thinkingDefault is explicitly configured, that value is used as-is
 * (e.g. "auto" → OpenRouter applies per-query complexity routing).
 */
const PASSTHROUGH_ROUTER_MODELS = new Set(["openrouter/auto"]);

'''
content = content.replace(anchor, passthrough_block + anchor, 1)
changes += 1

# 1c) Add "auto" to perModelThinking check
old_check = '''    perModelThinking === "adaptive"
  ) {'''
new_check = '''    perModelThinking === "adaptive" ||
    perModelThinking === "auto"
  ) {'''
if old_check in content:
    content = content.replace(old_check, new_check, 1)
    changes += 1
else:
    print("    FAIL: #31876 perModelThinking adaptive check not found", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print(f"    OK: #31876 model-selection.ts ({changes} changes)")
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 2) thinking.ts: Add "auto" to ThinkLevel + fix normalizeThinkLevel + guard resolveThinkingDefaultForModel ───
FILE="$SRC/auto-reply/thinking.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changes = 0

# 2a) Add "auto" to ThinkLevel union
old_type = 'export type ThinkLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "adaptive";'
new_type = '''export type ThinkLevel =
  | "off"
  | "minimal"
  | "low"
  | "medium"
  | "high"
  | "xhigh"
  | "adaptive"
  | "auto";'''
if old_type in content:
    content = content.replace(old_type, new_type, 1)
    changes += 1
else:
    print("    FAIL: #31876 ThinkLevel union not found in thinking.ts", file=sys.stderr)
    sys.exit(1)

# 2b) Separate "auto" from "adaptive" in normalizeThinkLevel
old_norm = '  if (collapsed === "adaptive" || collapsed === "auto") {\n    return "adaptive";\n  }'
new_norm = '  if (collapsed === "adaptive") {\n    return "adaptive";\n  }'
if old_norm in content:
    content = content.replace(old_norm, new_norm, 1)
    changes += 1
else:
    print("    FAIL: #31876 adaptive/auto collapse not found", file=sys.stderr)
    sys.exit(1)

# 2c) Add "auto" case after "think" → "minimal" block
old_think = '''  if (["think"].includes(key)) {
    return "minimal";
  }
  return undefined;'''
new_think = '''  if (["think"].includes(key)) {
    return "minimal";
  }
  // "auto" = let the provider decide; don't force reasoning_effort
  if (["auto", "automatic"].includes(key)) {
    return "auto";
  }
  return undefined;'''
if old_think in content:
    content = content.replace(old_think, new_think, 1)
    changes += 1
else:
    print("    FAIL: #31876 think/minimal block not found", file=sys.stderr)
    sys.exit(1)

# 2d) Guard resolveThinkingDefaultForModel against PASSTHROUGH models
old_reasoning = '  if (candidate?.reasoning) {\n    return "low";\n  }'
new_reasoning = '''  // Don't auto-promote thinking for pass-through routing models.
  // These models route to a downstream model; forcing reasoning_effort here
  // overrides the router's own complexity-based model selection.
  const PASSTHROUGH_ROUTER_MODELS = new Set(["openrouter/auto"]);
  const modelKeyStr = `${params.provider}/${params.model}`;
  if (
    candidate?.reasoning &&
    !PASSTHROUGH_ROUTER_MODELS.has(modelKeyStr)
  ) {
    return "low";
  }'''
if old_reasoning in content:
    content = content.replace(old_reasoning, new_reasoning, 1)
    changes += 1
else:
    print("    FAIL: #31876 candidate.reasoning block not found", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print(f"    OK: #31876 thinking.ts ({changes} changes)")
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 3) utils.ts: map "auto" to "off" ───
FILE="$SRC/agents/pi-embedded-runner/utils.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = '  if (level === "adaptive") {\n    return "medium";\n  }\n  return level;'
new = '''  if (level === "adaptive") {
    return "medium";
  }
  // "auto" means let the provider decide — don't force reasoning_effort.
  // pi-agent-core converts "off" → undefined, which omits reasoning_effort from the API request.
  if (level === "auto") {
    return "off";
  }
  return level;'''
if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #31876 utils.ts — auto→off mapping added")
else:
    print("    FAIL: #31876 adaptive block not found in utils.ts", file=sys.stderr)
    sys.exit(1)
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 4) proxy-stream-wrappers.ts: skip reasoning injection for "auto" + map to "medium" ───
FILE="$SRC/agents/pi-embedded-runner/proxy-stream-wrappers.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changes = 0

# 4a) Add "auto" → "medium" mapping in mapThinkingLevelToOpenRouterReasoningEffort
old_adaptive = '  if (thinkingLevel === "adaptive") {\n    return "medium";\n  }\n  return thinkingLevel;'
new_adaptive = '''  if (thinkingLevel === "adaptive" || thinkingLevel === "auto") {
    return "medium";
  }
  return thinkingLevel;'''
if old_adaptive in content:
    content = content.replace(old_adaptive, new_adaptive, 1)
    changes += 1
else:
    print("    FAIL: #31876 adaptive mapping not found in proxy-stream-wrappers.ts", file=sys.stderr)
    sys.exit(1)

# 4b) Skip reasoning injection for "auto" in normalizeProxyReasoningPayload
old_guard = '  if (!thinkingLevel || thinkingLevel === "off") {\n    return;\n  }'
new_guard = '  if (!thinkingLevel || thinkingLevel === "off" || thinkingLevel === "auto") {\n    return;\n  }'
if old_guard in content:
    content = content.replace(old_guard, new_guard, 1)
    changes += 1
else:
    print("    FAIL: #31876 off guard not found in proxy-stream-wrappers.ts", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print(f"    OK: #31876 proxy-stream-wrappers.ts ({changes} changes)")
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 5) zod-schema.agent-defaults.ts: add z.literal("auto") ───
FILE="$SRC/config/zod-schema.agent-defaults.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = '        z.literal("adaptive"),\n      ])\n      .optional(),'
new = '        z.literal("adaptive"),\n        z.literal("auto"),\n      ])\n      .optional(),'
if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #31876 zod-schema.agent-defaults.ts — auto literal added")
else:
    print("    FAIL: #31876 adaptive literal in zod schema not found", file=sys.stderr)
    sys.exit(1)
PYEOF
CHANGES=$((CHANGES + 1))

echo "    OK: #31876 reasoning effort openrouter/auto — $CHANGES files patched"
