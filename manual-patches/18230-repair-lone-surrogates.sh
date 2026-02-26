#!/usr/bin/env bash
set -euo pipefail
# PR #18230 — fix(sessions): repair lone surrogates in session history
# Adds repairLoneSurrogates function and integrates into sanitizeSessionHistory
SRC="${1:-.}/src"

REPAIR_FILE="$SRC/agents/session-transcript-repair.ts"
GOOGLE_FILE="$SRC/agents/pi-embedded-runner/google.ts"

if grep -q 'repairLoneSurrogates' "$REPAIR_FILE" 2>/dev/null; then
  echo "    SKIP: #18230 already applied"
  exit 0
fi

# 1) Add repairLoneSurrogates function to session-transcript-repair.ts
python3 - "$REPAIR_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Insert before "export type ToolUseRepairReport"
marker = 'export type ToolUseRepairReport'
idx = content.find(marker)
if idx == -1:
    print("ERROR: Could not find ToolUseRepairReport in session-transcript-repair.ts", file=sys.stderr)
    sys.exit(1)

new_code = '''// Matches a high surrogate not followed by a low surrogate, or a low surrogate
// not preceded by a high surrogate. These lone surrogates cause API rejections
// ("no low surrogate in string") and are typically produced by streaming delta
// assembly splitting supplementary plane characters.
const LONE_SURROGATE_RE = /[\\uD800-\\uDBFF](?![\\uDC00-\\uDFFF])|(?<![\\uD800-\\uDBFF])[\\uDC00-\\uDFFF]/g;

function repairStringLoneSurrogates(value: string): string {
  return value.replace(LONE_SURROGATE_RE, "\\uFFFD");
}

function deepRepairSurrogates(value: unknown): unknown {
  if (typeof value === "string") {
    return repairStringLoneSurrogates(value);
  }
  if (Array.isArray(value)) {
    let changed = false;
    const out = value.map((item) => {
      const repaired = deepRepairSurrogates(item);
      if (repaired !== item) {
        changed = true;
      }
      return repaired;
    });
    return changed ? out : value;
  }
  if (value && typeof value === "object") {
    let changed = false;
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      const repaired = deepRepairSurrogates(v);
      if (repaired !== v) {
        changed = true;
      }
      out[k] = repaired;
    }
    return changed ? out : value;
  }
  return value;
}

/**
 * Replace lone surrogates in all string values of the given messages.
 * This prevents 400 errors from LLM APIs that reject lone surrogates in
 * tool_use arguments or other content (e.g. "no low surrogate in string").
 */
export function repairLoneSurrogates(messages: AgentMessage[]): AgentMessage[] {
  return deepRepairSurrogates(messages) as AgentMessage[];
}

'''

content = content[:idx] + new_code + content[idx:]

with open(path, 'w') as f:
    f.write(content)
PYEOF

# 2) Add import and integrate into google.ts sanitizeSessionHistory pipeline
python3 - "$GOOGLE_FILE" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Add repairLoneSurrogates to the import from session-transcript-repair.js
# Robust: find any import block from session-transcript-repair.js and add the member
if 'repairLoneSurrogates' not in content:
    # Match: import { ... } from "../session-transcript-repair.js";
    # The import may span multiple lines and contain varying members
    pattern = re.compile(
        r'(import\s*\{)([^}]*)(}\s*from\s*"../session-transcript-repair\.js"\s*;)',
        re.DOTALL,
    )
    m = pattern.search(content)
    if m:
        members = m.group(2)
        # Add repairLoneSurrogates as first member
        if members.strip().startswith('\n') or '\n' in members:
            # Multiline import — add on new line after opening brace
            new_members = '\n  repairLoneSurrogates,' + members
        else:
            # Single-line import
            new_members = ' repairLoneSurrogates,' + members
        content = content[:m.start()] + m.group(1) + new_members + m.group(3) + content[m.end():]
        print("    OK: #18230 added repairLoneSurrogates to import in google.ts")
    else:
        print("    FAIL: #18230 cannot find session-transcript-repair import in google.ts", file=sys.stderr)
        sys.exit(1)
else:
    print("    SKIP: #18230 repairLoneSurrogates already imported in google.ts")

# Insert repairLoneSurrogates step between droppedThinking and sanitizeToolCallInputs
if 'repairedSurrogates' not in content:
    old_pipeline = 'const sanitizedToolCalls = sanitizeToolCallInputs(droppedThinking, {'
    new_pipeline = 'const repairedSurrogates = repairLoneSurrogates(droppedThinking);\n  const sanitizedToolCalls = sanitizeToolCallInputs(repairedSurrogates, {'
    if old_pipeline in content:
        content = content.replace(old_pipeline, new_pipeline, 1)
        print("    OK: #18230 added repairLoneSurrogates pipeline step in google.ts")
    else:
        print("    WARN: #18230 pipeline marker not found (may already be modified)")
else:
    print("    SKIP: #18230 pipeline step already present in google.ts")

with open(path, 'w') as f:
    f.write(content)
PYEOF

echo "    OK: #18230 fully applied"
