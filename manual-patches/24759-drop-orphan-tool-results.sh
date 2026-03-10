#!/usr/bin/env bash
# PR #24759 — fix(openai): drop orphan tool results after tool-call filtering
# When tool calls are filtered by allowlist, their corresponding tool results
# become orphans and cause API 400 errors with OpenAI responses API.
# This adds dropOrphanToolResults() and uses it as fallback when
# repairToolUseResultPairing is disabled.
#
# Changes:
# 1. session-transcript-repair.ts: Add dropOrphanToolResults function
# 2. pi-embedded-runner/google.ts: Import + use dropOrphanToolResults for OpenAI responses
set -euo pipefail
SRC="${1:-.}/src"

REPAIR_FILE="$SRC/agents/session-transcript-repair.ts"
GOOGLE_FILE="$SRC/agents/pi-embedded-runner/google.ts"

# Idempotency check
if grep -q 'dropOrphanToolResults' "$REPAIR_FILE" 2>/dev/null; then
  echo "    SKIP: #24759 already applied"
  exit 0
fi

[ -f "$REPAIR_FILE" ] || { echo "    FAIL: $REPAIR_FILE not found"; exit 1; }
[ -f "$GOOGLE_FILE" ] || { echo "    FAIL: $GOOGLE_FILE not found"; exit 1; }

# 1) session-transcript-repair.ts: Add dropOrphanToolResults before sanitizeToolUseResultPairing
python3 - "$REPAIR_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

marker = 'export function sanitizeToolUseResultPairing(messages: AgentMessage[]): AgentMessage[] {'

new_fn = '''export function dropOrphanToolResults(messages: AgentMessage[]): AgentMessage[] {
  let changed = false;
  const out: AgentMessage[] = [];
  let expectedToolCallIds: Set<string> | null = null;
  let seenToolResultIds: Set<string> | null = null;

  for (const msg of messages) {
    if (!msg || typeof msg !== "object") {
      expectedToolCallIds = null;
      seenToolResultIds = null;
      out.push(msg);
      continue;
    }

    const role = (msg as { role?: unknown }).role;
    if (role === "assistant") {
      out.push(msg);
      const assistant = msg as Extract<AgentMessage, { role: "assistant" }>;
      const stopReason = (assistant as { stopReason?: string }).stopReason;
      if (stopReason === "error" || stopReason === "aborted") {
        expectedToolCallIds = null;
        seenToolResultIds = null;
        continue;
      }
      const toolCalls = extractToolCallsFromAssistant(assistant);
      if (toolCalls.length > 0) {
        expectedToolCallIds = new Set(toolCalls.map((toolCall) => toolCall.id));
        seenToolResultIds = new Set<string>();
      } else {
        expectedToolCallIds = null;
        seenToolResultIds = null;
      }
      continue;
    }

    if (role === "toolResult") {
      if (!expectedToolCallIds || !seenToolResultIds) {
        changed = true;
        continue;
      }
      const toolResult = msg as Extract<AgentMessage, { role: "toolResult" }>;
      const id = extractToolResultId(toolResult);
      if (!id || !expectedToolCallIds.has(id) || seenToolResultIds.has(id)) {
        changed = true;
        continue;
      }
      seenToolResultIds.add(id);
      out.push(msg);
      continue;
    }

    expectedToolCallIds = null;
    seenToolResultIds = null;
    out.push(msg);
  }

  return changed ? out : messages;
}

'''

if marker not in content:
    print("    FAIL: #24759 sanitizeToolUseResultPairing marker not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(marker, new_fn + marker, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #24759 dropOrphanToolResults added to session-transcript-repair.ts")
PYEOF

# 2) google.ts: Import dropOrphanToolResults + use it for OpenAI responses API
python3 - "$GOOGLE_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 2a) Add import — handle both with and without repairLoneSurrogates
old_import_with_rls = '''import {
  repairLoneSurrogates,
  sanitizeToolCallInputs,
  stripToolResultDetails,
  sanitizeToolUseResultPairing,'''

old_import_without_rls = '''import {
  sanitizeToolCallInputs,
  stripToolResultDetails,
  sanitizeToolUseResultPairing,'''

if old_import_with_rls in content:
    new_import = '''import {
  dropOrphanToolResults,
  repairLoneSurrogates,
  sanitizeToolCallInputs,
  stripToolResultDetails,
  sanitizeToolUseResultPairing,'''
    content = content.replace(old_import_with_rls, new_import, 1)
elif old_import_without_rls in content:
    new_import = '''import {
  dropOrphanToolResults,
  sanitizeToolCallInputs,
  stripToolResultDetails,
  sanitizeToolUseResultPairing,'''
    content = content.replace(old_import_without_rls, new_import, 1)
else:
    print("    FAIL: #24759 google.ts import pattern not found", file=sys.stderr)
    sys.exit(1)

# 2b) Move isOpenAIResponsesApi up and add dropOrphanToolResults fallback
old_repair = '''  const repairedTools = policy.repairToolUseResultPairing
    ? sanitizeToolUseResultPairing(sanitizedToolCalls)
    : sanitizedToolCalls;'''

new_repair = '''  const isOpenAIResponsesApi =
    params.modelApi === "openai-responses" || params.modelApi === "openai-codex-responses";
  const repairedTools = policy.repairToolUseResultPairing
    ? sanitizeToolUseResultPairing(sanitizedToolCalls)
    : isOpenAIResponsesApi
      ? dropOrphanToolResults(sanitizedToolCalls)
      : sanitizedToolCalls;'''

if old_repair not in content:
    print("    FAIL: #24759 google.ts repairedTools pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_repair, new_repair, 1)

# 2c) Remove the old isOpenAIResponsesApi declaration (now moved up)
old_decl = '\n  const isOpenAIResponsesApi =\n    params.modelApi === "openai-responses" || params.modelApi === "openai-codex-responses";'
if old_decl in content:
    # Only remove the second occurrence (the original position)
    first_idx = content.find('isOpenAIResponsesApi')
    second_idx = content.find(old_decl, first_idx + 10)
    if second_idx > -1:
        content = content[:second_idx] + content[second_idx + len(old_decl):]

with open(path, 'w') as f:
    f.write(content)
print("    OK: #24759 dropOrphanToolResults integrated into google.ts sanitizeSessionHistory")
PYEOF

echo "    OK: #24759 drop orphan tool results applied (2 files)"
