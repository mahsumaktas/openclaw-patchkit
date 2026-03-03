#!/usr/bin/env bash
set -euo pipefail
cd "$1"

PATCH_ID="PR-27477"

# --- File 1: src/agents/pi-tools.params.ts ---
# Add oldString->oldText and newString->newText alias normalization
# (normalizeToolParams lives here, re-exported by pi-tools.read.ts)
FILE1="src/agents/pi-tools.params.ts"

if [[ ! -f "$FILE1" ]]; then
  echo "$PATCH_ID: ERROR - $FILE1 not found"
  exit 1
fi

MARKER1="oldString"
if grep -q "$MARKER1" "$FILE1"; then
  echo "$PATCH_ID: $FILE1 already patched (idempotent skip)"
else
  python3 - "$FILE1" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Add oldString -> oldText after old_string -> oldText block
# and newString -> newText after new_string -> newText block

old_block = '''  // old_string \u2192 oldText (edit)
  if ("old_string" in normalized && !("oldText" in normalized)) {
    normalized.oldText = normalized.old_string;
    delete normalized.old_string;
  }
  // new_string \u2192 newText (edit)
  if ("new_string" in normalized && !("newText" in normalized)) {
    normalized.newText = normalized.new_string;
    delete normalized.new_string;
  }'''

new_block = '''  // old_string \u2192 oldText (edit)
  if ("old_string" in normalized && !("oldText" in normalized)) {
    normalized.oldText = normalized.old_string;
    delete normalized.old_string;
  }
  // oldString \u2192 oldText (edit)
  if ("oldString" in normalized && !("oldText" in normalized)) {
    normalized.oldText = normalized.oldString;
    delete normalized.oldString;
  }
  // new_string \u2192 newText (edit)
  if ("new_string" in normalized && !("newText" in normalized)) {
    normalized.newText = normalized.new_string;
    delete normalized.new_string;
  }
  // newString \u2192 newText (edit)
  if ("newString" in normalized && !("newText" in normalized)) {
    normalized.newText = normalized.newString;
    delete normalized.newString;
  }'''

if old_block not in content:
    print(f"ERROR: Could not find old_string/new_string normalization block in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_block, new_block, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"Patched {filepath}")
PYEOF
  echo "$PATCH_ID: Patched $FILE1"
fi

# --- File 2: src/agents/tool-mutation.ts ---
# Add "file_path" to fingerprint target keys
FILE2="src/agents/tool-mutation.ts"

if [[ ! -f "$FILE2" ]]; then
  echo "$PATCH_ID: ERROR - $FILE2 not found"
  exit 1
fi

MARKER2='"file_path"'
if grep -q "$MARKER2" "$FILE2"; then
  echo "$PATCH_ID: $FILE2 already patched (idempotent skip)"
else
  python3 - "$FILE2" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Add "file_path" after "path" in the fingerprint key list
old_keys = '''  for (const key of [
    "path",
    "filePath",'''

new_keys = '''  for (const key of [
    "path",
    "file_path",
    "filePath",'''

if old_keys not in content:
    print(f"ERROR: Could not find fingerprint key list in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_keys, new_keys, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"Patched {filepath}")
PYEOF
  echo "$PATCH_ID: Patched $FILE2"
fi

# --- File 3: src/agents/tool-display-common.ts ---
# Add newString fallback to resolveWriteDetail content resolution
FILE3="src/agents/tool-display-common.ts"

if [[ ! -f "$FILE3" ]]; then
  echo "$PATCH_ID: ERROR - $FILE3 not found"
  exit 1
fi

MARKER3="newString"
if grep -q "$MARKER3" "$FILE3"; then
  echo "$PATCH_ID: $FILE3 already patched (idempotent skip)"
else
  python3 - "$FILE3" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Add newString as another fallback in the content resolution chain
old_content_chain = '''        : typeof record.new_string === "string"
          ? record.new_string
          : undefined;'''

new_content_chain = '''        : typeof record.new_string === "string"
          ? record.new_string
          : typeof record.newString === "string"
            ? record.newString
            : undefined;'''

if old_content_chain not in content:
    print(f"ERROR: Could not find content chain in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_content_chain, new_content_chain, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"Patched {filepath}")
PYEOF
  echo "$PATCH_ID: Patched $FILE3"
fi

echo "$PATCH_ID: Done"
