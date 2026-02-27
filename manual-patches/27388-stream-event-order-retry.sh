#!/usr/bin/env bash
# PR #27388 — fix(agent): retry on Anthropic stream event order errors
# Adds isStreamEventOrderError() detector and retry logic for transient
# Anthropic SDK stream protocol errors (e.g., message_start before message_stop).
# Conflict with #25219: both touch run.ts promptError block. This script
# handles both pre- and post-#25219 code.
set -euo pipefail

SRC="${1:?Usage: $0 <openclaw-source-dir>}/src"
ERRORS="$SRC/agents/pi-embedded-helpers/errors.ts"
HELPERS="$SRC/agents/pi-embedded-helpers.ts"
RUN="$SRC/agents/pi-embedded-runner/run.ts"

# ── Idempotency check ──
if grep -q 'isStreamEventOrderError' "$ERRORS" 2>/dev/null; then
  echo "    SKIP: #27388 already applied"
  exit 0
fi

[ -f "$ERRORS" ] || { echo "    FAIL: errors.ts not found"; exit 1; }
[ -f "$RUN" ] || { echo "    FAIL: run.ts not found"; exit 1; }

# ── 1. errors.ts: Add isStreamEventOrderError function ──
python3 - "$ERRORS" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Find a good insertion point — before the first non-error-detection export
# Try to insert before isTransientHttpError or at end of file before last export
import re

# Insert before the last function definition
marker_patterns = [
    'export function isTransientHttpError',
    'export function isTransient',
    'function stripFinalTagsFromText',
]

insert_pos = None
for pattern in marker_patterns:
    idx = content.find(pattern)
    if idx >= 0:
        insert_pos = idx
        break

if insert_pos is None:
    # Fallback: insert before last export
    idx = content.rfind('\nexport ')
    if idx >= 0:
        insert_pos = idx + 1

if insert_pos is None:
    print("    FAIL: #27388 no suitable insertion point in errors.ts")
    sys.exit(1)

insert_block = '''const STREAM_EVENT_ORDER_RE = /unexpected event order|event_order_error|received.*before.*message_stop/i;

/**
 * Detects stream protocol errors from the Anthropic SDK (e.g., receiving
 * message_start before the previous message_stop). These are transient
 * server-side issues and safe to retry.
 */
export function isStreamEventOrderError(raw: string): boolean {
  return STREAM_EVENT_ORDER_RE.test(raw);
}

'''

content = content[:insert_pos] + insert_block + content[insert_pos:]

with open(path, 'w') as f:
    f.write(content)
print("    OK: #27388 isStreamEventOrderError added to errors.ts")
PYEOF

if [ $? -ne 0 ]; then
  echo "    FAIL: errors.ts patch failed"
  exit 1
fi

# ── 2. pi-embedded-helpers.ts: Add re-export ──
if [ -f "$HELPERS" ]; then
  python3 - "$HELPERS" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if 'isStreamEventOrderError' in content:
    print("    SKIP: #27388 re-export already present")
    sys.exit(0)

# Find the errors.ts re-export block
import re
m = re.search(r'(export \{[^}]*isTransientHttpError[^}]*\} from ["\'])', content)
if m:
    old = m.group(0)
    # Add before isTransientHttpError
    new = old.replace('isTransientHttpError', 'isStreamEventOrderError,\n  isTransientHttpError')
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #27388 re-export added to pi-embedded-helpers.ts")
else:
    # Try simpler pattern
    old = '  isTransientHttpError,'
    if old in content:
        new = '  isStreamEventOrderError,\n  isTransientHttpError,'
        content = content.replace(old, new, 1)
        with open(path, 'w') as f:
            f.write(content)
        print("    OK: #27388 re-export added (simple match)")
    else:
        print("    WARN: #27388 could not add re-export — may need manual review")
PYEOF
fi

# ── 3. run.ts: Add import + retry constant + retry block ──
python3 - "$RUN" << 'PYEOF'
import sys
import re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 3a. Add import — must target pi-embedded-helpers import block specifically
if 'isStreamEventOrderError' not in content:
    # Find the exact pi-embedded-helpers import block by looking for its from clause
    # and working backwards to find the opening brace
    helpers_from = '} from "../pi-embedded-helpers.js";'
    if helpers_from in content:
        # Insert before the closing } of that specific import
        old = '  isFailoverErrorMessage,'
        new = '  isFailoverErrorMessage,\n  isStreamEventOrderError,'
        if old in content:
            content = content.replace(old, new, 1)
            print("    OK: #27388 import added to run.ts")
        else:
            # Fallback: try to add before type FailoverReason
            old2 = '  type FailoverReason,'
            if old2 in content:
                content = content.replace(old2, '  isStreamEventOrderError,\n' + old2, 1)
                print("    OK: #27388 import added to run.ts (alt)")
            else:
                print("    WARN: #27388 could not add import to run.ts")
    else:
        print("    WARN: #27388 pi-embedded-helpers import not found")

# 3b. Add MAX_STREAM_EVENT_ORDER_RETRIES constant
if 'MAX_STREAM_EVENT_ORDER_RETRIES' not in content:
    # Find overflow compaction constant
    overflow_const = 'const MAX_OVERFLOW_COMPACTION_ATTEMPTS = 3;'
    if overflow_const in content:
        content = content.replace(
            overflow_const,
            overflow_const + '\n      const MAX_STREAM_EVENT_ORDER_RETRIES = 2;',
            1
        )
        print("    OK: #27388 MAX_STREAM_EVENT_ORDER_RETRIES constant added")
    else:
        # Try regex for flexible whitespace
        m = re.search(r'(const MAX_OVERFLOW_COMPACTION_ATTEMPTS\s*=\s*\d+;)', content)
        if m:
            content = content.replace(
                m.group(1),
                m.group(1) + '\n      const MAX_STREAM_EVENT_ORDER_RETRIES = 2;',
                1
            )
            print("    OK: #27388 constant added (regex match)")

# 3c. Add counter
if 'streamEventOrderRetries' not in content:
    overflow_counter = 'let overflowCompactionAttempts = 0;'
    if overflow_counter in content:
        content = content.replace(
            overflow_counter,
            overflow_counter + '\n      let streamEventOrderRetries = 0;',
            1
        )
        print("    OK: #27388 streamEventOrderRetries counter added")
    else:
        m = re.search(r'(let overflowCompactionAttempts\s*=\s*0;)', content)
        if m:
            content = content.replace(
                m.group(1),
                m.group(1) + '\n      let streamEventOrderRetries = 0;',
                1
            )

# 3d. Add retry block before promptError check
if 'isStreamEventOrderError' in content and 'streamEventOrderRetries < MAX_STREAM_EVENT_ORDER_RETRIES' not in content:
    # Find the promptError guard — works with both pre- and post-#25219
    prompt_patterns = [
        r'(          if \(promptError && \(!aborted \|\| isStreamingAbort\)\) \{)',
        r'(          if \(promptError && !aborted\) \{)',
    ]

    inserted = False
    for pattern in prompt_patterns:
        m = re.search(pattern, content)
        if m:
            retry_block = """          // Stream protocol error (e.g., Anthropic SDK received message_start
          // before the previous message_stop). Transient server-side issue; retry.
          if (
            !aborted &&
            assistantErrorText &&
            isStreamEventOrderError(assistantErrorText) &&
            streamEventOrderRetries < MAX_STREAM_EVENT_ORDER_RETRIES
          ) {
            streamEventOrderRetries++;
            log.warn(
              `stream event order error (attempt ${streamEventOrderRetries}/${MAX_STREAM_EVENT_ORDER_RETRIES}); retrying`,
            );
            continue;
          }

"""
            pos = m.start()
            content = content[:pos] + retry_block + content[pos:]
            inserted = True
            print("    OK: #27388 retry block added to run.ts")
            break

    if not inserted:
        print("    WARN: #27388 could not find promptError guard — retry block not added")

with open(path, 'w') as f:
    f.write(content)
PYEOF

if [ $? -ne 0 ]; then
  echo "    FAIL: run.ts patch failed"
  exit 1
fi

echo "    DONE: 27388-stream-event-order-retry applied"
