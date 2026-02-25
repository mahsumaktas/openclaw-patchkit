#!/usr/bin/env bash
# PR #23184 - fix(auto-reply): prevent reminder guard note leaking into channel messages
set -euo pipefail
cd "$1"

RUNNER="src/auto-reply/reply/agent-runner.ts"
TYPES="src/auto-reply/types.ts"

if grep -q 'systemNote: UNSCHEDULED_REMINDER_NOTE' "$RUNNER" 2>/dev/null; then
  echo "SKIP: $RUNNER already patched (systemNote present)"
else
  python3 <<'PYEOF'
import sys

path = "src/auto-reply/reply/agent-runner.ts"
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
