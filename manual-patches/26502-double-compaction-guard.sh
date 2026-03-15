#!/usr/bin/env bash
# PR #26502 — fix: prevent double compaction from destroying preserved messages
# When a compaction finishes and leaves a stale usage.totalTokens from a kept
# assistant message, the next prompt() call can trigger a spurious re-compaction.
# That second compaction finds only custom/compaction entries -> destroys everything
# the first compaction preserved.
#
# Two-layer fix:
# 1. attempt.ts: skip cache-ttl entry insertion if compaction already occurred this attempt
# 2. compaction-safeguard.ts: cancel compaction when messagesToSummarize has no real
#    conversation messages (user/assistant/toolResult)
#
# NOTE (v2026.3.13): Part 2 was merged upstream in a different form. The function
# isRealConversationMessage() already exists at line 182, and the handler already
# calls preparation.messagesToSummarize.some(isRealConversationMessage) at line 705.
# The destructuring also changed: { preparation, customInstructions: eventInstructions, signal }
# This script now detects the upstream merge and skips Part 2 when present.
#
# See: https://github.com/openclaw/openclaw/issues/26458
set -euo pipefail

WORKDIR="${1:-$(ls -d /tmp/openclaw-patch-build-* 2>/dev/null | head -1)}"
if [ -z "$WORKDIR" ] || [ ! -d "$WORKDIR" ]; then
  echo "FAIL: No build workspace found"
  exit 1
fi
cd "$WORKDIR"

ATTEMPT_FILE="src/agents/pi-embedded-runner/run/attempt.ts"
SAFEGUARD_FILE="src/agents/pi-extensions/compaction-safeguard.ts"

# ── Idempotency checks ──
if grep -q 'compactionOccurredThisAttempt' "$ATTEMPT_FILE" 2>/dev/null; then
  echo "SKIP: #26502 already applied to $ATTEMPT_FILE"
  ATTEMPT_DONE=1
else
  ATTEMPT_DONE=0
fi

# Part 2: Check if upstream already has the double-compaction guard.
# v2026.3.13 has isRealConversationMessage() and uses it in the handler.
# Also accept the original hasRealMessages sentinel from older script versions.
if grep -q 'isRealConversationMessage' "$SAFEGUARD_FILE" 2>/dev/null && \
   grep -q 'messagesToSummarize.some(isRealConversationMessage)' "$SAFEGUARD_FILE" 2>/dev/null; then
  echo "SKIP: #26502 Part 2 already present upstream in $SAFEGUARD_FILE (isRealConversationMessage)"
  SAFEGUARD_DONE=1
elif grep -q 'hasRealMessages' "$SAFEGUARD_FILE" 2>/dev/null; then
  echo "SKIP: #26502 Part 2 already applied to $SAFEGUARD_FILE (hasRealMessages)"
  SAFEGUARD_DONE=1
else
  SAFEGUARD_DONE=0
fi

if [ "$ATTEMPT_DONE" = "1" ] && [ "$SAFEGUARD_DONE" = "1" ]; then
  echo "OK: #26502 fully applied (both files)"
  exit 0
fi

# ── Patch 1: attempt.ts — skip cache-ttl entry when compaction occurred ──
if [ "$ATTEMPT_DONE" = "0" ]; then
  if ! [ -f "$ATTEMPT_FILE" ]; then
    echo "FAIL: $ATTEMPT_FILE not found"
    exit 1
  fi

  python3 - "$ATTEMPT_FILE" << 'PYEOF'
import sys

with open(sys.argv[1], "r") as f:
    content = f.read()

# The PR changes:
#   if (!timedOutDuringCompaction) {
# to:
#   const compactionOccurredThisAttempt = getCompactionCount() > 0;
#   if (!timedOutDuringCompaction && !compactionOccurredThisAttempt) {

old_pattern = "if (!timedOutDuringCompaction) {\n          const shouldTrackCacheTtl ="
new_pattern = """// Also skip when compaction occurred during this attempt — the cache-ttl custom
        // entry would be the only non-compaction entry in the session, bypassing
        // prepareCompaction()'s double-compaction guard and enabling a spurious
        // re-compaction on the next prompt() call (which uses stale usage.totalTokens
        // from kept assistant messages). See: https://github.com/openclaw/openclaw/issues/26458
        const compactionOccurredThisAttempt = getCompactionCount() > 0;
        if (!timedOutDuringCompaction && !compactionOccurredThisAttempt) {
          const shouldTrackCacheTtl ="""

if old_pattern in content:
    content = content.replace(old_pattern, new_pattern, 1)
    with open(sys.argv[1], "w") as f:
        f.write(content)
    print("OK: #26502 attempt.ts — added compactionOccurredThisAttempt guard")
else:
    # Try alternate indentation (some versions use different spacing)
    old_alt = "if (!timedOutDuringCompaction) {\n        const shouldTrackCacheTtl ="
    if old_alt in content:
        new_alt = new_pattern.replace("          const shouldTrackCacheTtl =", "        const shouldTrackCacheTtl =")
        content = content.replace(old_alt, new_alt, 1)
        with open(sys.argv[1], "w") as f:
            f.write(content)
        print("OK: #26502 attempt.ts — added compactionOccurredThisAttempt guard (alt indent)")
    else:
        print("FAIL: #26502 cannot find timedOutDuringCompaction guard in attempt.ts")
        sys.exit(1)
PYEOF
fi

# ── Patch 2: compaction-safeguard.ts — cancel compaction when no real messages ──
if [ "$SAFEGUARD_DONE" = "0" ]; then
  if ! [ -f "$SAFEGUARD_FILE" ]; then
    echo "FAIL: $SAFEGUARD_FILE not found"
    exit 1
  fi

  python3 - "$SAFEGUARD_FILE" << 'PYEOF'
import sys
import re

with open(sys.argv[1], "r") as f:
    content = f.read()

# v2026.3.13 changed the destructuring to use a rename:
#   const { preparation, customInstructions: eventInstructions, signal } = event;
# Older versions used:
#   const { preparation, customInstructions, signal } = event;
# We need to find whichever form is present.

# Strategy: find the api.on("session_before_compact" handler and its destructuring,
# then insert the guard block right after it.

# Try v2026.3.13 form first (with rename)
anchor_v313 = re.search(
    r'(const \{ preparation,\s*customInstructions:\s*\w+,\s*signal \} = event;)',
    content,
)

# Try original form
anchor_orig = re.search(
    r'(const \{ preparation,\s*customInstructions,\s*signal \} = event;)',
    content,
)

anchor_match = anchor_v313 or anchor_orig
if not anchor_match:
    print("FAIL: #26502 cannot find preparation destructuring in compaction-safeguard.ts")
    sys.exit(1)

anchor = anchor_match.group(0)

# Check if guard is already there (isRealConversationMessage used right after)
# Look for the pattern within 500 chars after the anchor
anchor_pos = content.find(anchor)
nearby = content[anchor_pos:anchor_pos + 500]
if "isRealConversationMessage" in nearby or "hasRealMessages" in nearby:
    print("SKIP: #26502 guard already present near handler entry")
    sys.exit(0)

# Check if isRealConversationMessage helper exists in the file
if "function isRealConversationMessage" in content:
    # Use the existing helper — cleaner approach matching upstream style
    guard_code = anchor + """

    // Guard: Cancel compaction if there are no real conversation messages to summarize.
    // This prevents "double compaction" where a stale usage.totalTokens from a kept
    // assistant message (preserved across a compaction boundary) triggers an immediate
    // re-compaction on an already-compacted session. In that scenario,
    // messagesToSummarize is empty (only custom/compaction entries remain), and
    // proceeding would destroy all messages the first compaction preserved.
    // See: https://github.com/openclaw/openclaw/issues/26458
    if (!preparation.messagesToSummarize.some(isRealConversationMessage)) {
      log.warn(
        "Compaction safeguard: cancelling compaction with no real conversation messages to summarize.",
      );
      return { cancel: true };
    }"""
else:
    # Inline the check (older codebase without the helper)
    guard_code = anchor + """

    // Guard: Cancel compaction if there are no real conversation messages to summarize.
    // This prevents "double compaction" where a stale usage.totalTokens from a kept
    // assistant message (preserved across a compaction boundary) triggers an immediate
    // re-compaction on an already-compacted session. In that scenario,
    // messagesToSummarize is empty (only custom/compaction entries remain), and
    // proceeding would destroy all messages the first compaction preserved.
    // See: https://github.com/openclaw/openclaw/issues/26458
    const hasRealMessages = preparation.messagesToSummarize.some(
      (msg: AgentMessage) =>
        msg.role === "user" || msg.role === "assistant" || msg.role === "toolResult",
    );
    if (!hasRealMessages) {
      log.warn(
        "Compaction safeguard: cancelling compaction — no real conversation messages to summarize " +
          `(messagesToSummarize has ${preparation.messagesToSummarize.length} entries, ` +
          `turnPrefixMessages has ${(preparation.turnPrefixMessages ?? []).length} entries). ` +
          "This likely indicates a spurious re-compaction triggered by stale usage data.",
      );
      return { cancel: true };
    }"""

content = content.replace(anchor, guard_code, 1)

with open(sys.argv[1], "w") as f:
    f.write(content)

print("OK: #26502 compaction-safeguard.ts — added double-compaction guard")
PYEOF
fi

echo "OK: #26502 double-compaction-guard fully applied"
