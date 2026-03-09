#!/usr/bin/env bash
# PR #23184 - fix(auto-reply): prevent reminder guard note leaking into channel messages
# Moves the unscheduled-reminder guardrail note from the user-visible `text` field
# to a new internal `systemNote` field on ReplyPayload, so it no longer leaks into
# channel messages.
#
# v2026.3.7: appendUnscheduledReminderNote was extracted to
# agent-runner-reminder-guard.ts (no longer inline in agent-runner.ts).
#
# Source changes:
#   - src/auto-reply/reply/agent-runner-reminder-guard.ts: use systemNote instead of text
#   - src/auto-reply/types.ts: add systemNote?: string to ReplyPayload
set -euo pipefail
cd "$1"

GUARD="src/auto-reply/reply/agent-runner-reminder-guard.ts"
TYPES="src/auto-reply/types.ts"

# ─── Patch 1: agent-runner-reminder-guard.ts ──────────────────────────────────
if grep -q 'systemNote: UNSCHEDULED_REMINDER_NOTE' "$GUARD" 2>/dev/null; then
  echo "SKIP: $GUARD already patched (systemNote present)"
else
  python3 <<'PYEOF'
import sys

path = "src/auto-reply/reply/agent-runner-reminder-guard.ts"
with open(path, "r") as f:
    content = f.read()

old = (
    '    appended = true;\n'
    '    const trimmed = payload.text.trimEnd();\n'
    '    return {\n'
    '      ...payload,\n'
    '      text: `${trimmed}\\n\\n${UNSCHEDULED_REMINDER_NOTE}`,\n'
    '    };'
)

new = (
    '    appended = true;\n'
    '    return {\n'
    '      ...payload,\n'
    '      systemNote: UNSCHEDULED_REMINDER_NOTE,\n'
    '    };'
)

if old not in content:
    print("ERROR: Could not find expected code block in " + path, file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new, 1)
with open(path, "w") as f:
    f.write(content)
print("OK: Patched " + path)
PYEOF
fi

# ─── Patch 2: types.ts ───────────────────────────────────────────────────────
# Add `systemNote?: string` field to ReplyPayload type after `isError`.
if grep -q 'systemNote?: string' "$TYPES" 2>/dev/null; then
  echo "SKIP: $TYPES already patched (systemNote field present)"
else
  sed -i.bak '/^  isError?: boolean;$/a\
  /** Internal system note (not sent to channels). Used for guardrail annotations. */\
  systemNote?: string;' "$TYPES"
  rm -f "${TYPES}.bak"
  echo "OK: Patched $TYPES"
fi

echo "DONE: PR #23184 applied successfully"
