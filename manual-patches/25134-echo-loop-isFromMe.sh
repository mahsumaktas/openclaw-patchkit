#!/usr/bin/env bash
# PR #25134 — fix(bluebubbles): prevent echo loop by coercing isFromMe strings
# BlueBubbles webhooks can send isFromMe as a string ("true"/"false"/"1"/"0")
# instead of a boolean. The strict `readBoolean` check returns undefined for
# string values, causing fromMe to be undefined, which bypasses the echo loop
# filter and makes the bot respond to its own messages.
#
# Fix: add readBooleanLike() that handles string coercion, and replace the two
# readBoolean(message, "isFromMe") calls in normalizeWebhookMessage and
# normalizeWebhookReaction with readBooleanLike.
set -euo pipefail

SRC="${1:-.}"

FILE="$SRC/extensions/bluebubbles/src/monitor-normalize.ts"
if [ ! -f "$FILE" ]; then
  echo "    FAIL: #25134 target file not found: $FILE"
  exit 1
fi

# Idempotency check
if grep -q 'readBooleanLike\|#25134' "$FILE"; then
  echo "    SKIP: #25134 already applied"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changed = False

# --- Change 1: Add readBooleanLike function after readBoolean ---
read_boolean_fn = '''function readBoolean(record: Record<string, unknown> | null, key: string): boolean | undefined {
  if (!record) {
    return undefined;
  }
  const value = record[key];
  return typeof value === "boolean" ? value : undefined;
}'''

read_boolean_like_fn = '''function readBooleanLike(record: Record<string, unknown> | null, key: string): boolean | undefined {
  if (!record) {
    return undefined;
  }
  const value = record[key];
  if (typeof value === "boolean") {
    return value;
  }
  if (value === "true" || value === "1") {
    return true;
  }
  if (value === "false" || value === "0") {
    return false;
  }
  return undefined;
}'''

if read_boolean_fn in content:
    content = content.replace(
        read_boolean_fn,
        read_boolean_fn + '\n\n' + read_boolean_like_fn,
        1,
    )
    changed = True
    print("    OK: #25134 added readBooleanLike function")
else:
    print("    FAIL: #25134 cannot find readBoolean function definition", file=sys.stderr)
    sys.exit(1)

# --- Change 2: Replace readBoolean with readBooleanLike for isFromMe calls ---
# There are exactly 2 occurrences for isFromMe (normalizeWebhookMessage + normalizeWebhookReaction)
old_from_me = 'readBoolean(message, "isFromMe") ?? readBoolean(message, "is_from_me")'
new_from_me = 'readBooleanLike(message, "isFromMe") ?? readBooleanLike(message, "is_from_me")'

count = content.count(old_from_me)
if count == 0:
    print("    FAIL: #25134 cannot find readBoolean isFromMe pattern", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_from_me, new_from_me)
changed = True
print(f"    OK: #25134 replaced {count} readBoolean->readBooleanLike isFromMe call(s)")

if changed:
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #25134 monitor-normalize.ts patched — echo loop prevention applied")
else:
    print("    SKIP: #25134 all changes already applied")
PYEOF
