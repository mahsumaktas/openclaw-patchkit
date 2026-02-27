#!/usr/bin/env bash
# PR #15050 — fix: transcript corruption resilience, skip format errors in auth profile rotation
# NOTE: session-transcript-repair.ts changes are COVERED BY #14328 (strip incomplete tool_use).
# This script only applies the run.ts changes:
# 1. maybeMarkAuthProfileFailure: skip format errors (400 Bad Request)
# 2. shouldRotate: exclude format errors from profile rotation
set +e

SRC="${1:?Usage: $0 <openclaw-source-dir>}"

RUN="$SRC/src/agents/pi-embedded-runner/run.ts"

if [ ! -f "$RUN" ]; then
  echo "SKIP: run.ts not found"
  exit 0
fi

# ── Idempotency check ──
if grep -q 'reason === "format"' "$RUN"; then
  echo "    SKIP: #15050 already applied"
  exit 0
fi

# ── 1. Patch run.ts — maybeMarkAuthProfileFailure: skip format errors ──
python3 -c "
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old_guard = 'if (!profileId || !reason || reason === \"timeout\") {'
new_guard = 'if (!profileId || !reason || reason === \"timeout\" || reason === \"format\") {'

if old_guard not in content:
    print('    ERROR: Could not find maybeMarkAuthProfileFailure guard in run.ts')
    sys.exit(1)

content = content.replace(old_guard, new_guard, 1)

with open(path, 'w') as f:
    f.write(content)
print('    OK: run.ts maybeMarkAuthProfileFailure patched')
" "$RUN"

if [ $? -ne 0 ]; then
  echo "    FAIL: Could not patch run.ts maybeMarkAuthProfileFailure"
  exit 1
fi

# ── 2. Patch run.ts — shouldRotate: exclude format errors ──
python3 -c "
import sys
import re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Match the shouldRotate line — may have varying whitespace
pattern = r'(const shouldRotate =\s*\n\s*)\(!aborted && failoverFailure\) \|\| \(timedOut && !timedOutDuringCompaction\);'
replacement = r'''\1(timedOut && !timedOutDuringCompaction) || (!aborted && failoverFailure && assistantFailoverReason !== \"format\");'''

new_content, count = re.subn(pattern, replacement, content, count=1)

if count == 0:
    # Try alternate pattern (after #25219 changes)
    pattern2 = r'(const shouldRotate =\s*\n\s*)\(!aborted && failoverFailure\)'
    if re.search(pattern2, content):
        new_content = re.sub(
            pattern2,
            r'\1(!aborted && failoverFailure && assistantFailoverReason !== \"format\")',
            content, count=1
        )
        count = 1

if count == 0:
    print('    WARN: shouldRotate pattern not found — skipping (may already be different)')
else:
    with open(path, 'w') as f:
        f.write(new_content)
    print('    OK: run.ts shouldRotate patched')
" "$RUN"

echo "    DONE: 15050-transcript-corruption-resilience applied (run.ts only)"
