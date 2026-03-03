#!/usr/bin/env bash
set -euo pipefail
cd "$1"

PATCH_ID="PR-26282"

# --- File 1: src/media/store.ts ---
# Change saveMediaBuffer to throw MediaFetchError instead of plain Error for size limit
FILE1="src/media/store.ts"

if [[ ! -f "$FILE1" ]]; then
  echo "$PATCH_ID: ERROR - $FILE1 not found"
  exit 1
fi

MARKER1='MediaFetchError'
if grep -q "$MARKER1" "$FILE1"; then
  echo "$PATCH_ID: $FILE1 already patched (idempotent skip)"
else
  python3 - "$FILE1" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# 1. Add import for MediaFetchError
old_import = 'import { detectMime, extensionForMime } from "./mime.js";'
new_import = 'import { MediaFetchError } from "./fetch.js";\nimport { detectMime, extensionForMime } from "./mime.js";'

if old_import not in content:
    print(f"ERROR: Could not find mime import in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import, new_import, 1)

# 2. Replace the size check error throw
old_throw = '    throw new Error(`Media exceeds ${(maxBytes / (1024 * 1024)).toFixed(0)}MB limit`);'
new_throw = '    throw new MediaFetchError(\n      "max_bytes",\n      `Media exceeds ${(maxBytes / (1024 * 1024)).toFixed(0)}MB limit (${buffer.byteLength} bytes > ${maxBytes})`,\n    );'

if old_throw not in content:
    print(f"ERROR: Could not find size limit throw in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_throw, new_throw, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"Patched {filepath}")
PYEOF
  echo "$PATCH_ID: Patched $FILE1"
fi

# --- File 2: src/telegram/bot-handlers.ts ---
# Add MediaFetchError max_bytes check to isMediaSizeLimitError
FILE2="src/telegram/bot-handlers.ts"

if [[ ! -f "$FILE2" ]]; then
  echo "$PATCH_ID: ERROR - $FILE2 not found"
  exit 1
fi

MARKER2='err.code === "max_bytes"'
if grep -q "$MARKER2" "$FILE2"; then
  echo "$PATCH_ID: $FILE2 already patched (idempotent skip)"
else
  python3 - "$FILE2" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Add MediaFetchError check at start of isMediaSizeLimitError
old_fn = '''function isMediaSizeLimitError(err: unknown): boolean {
  const errMsg = String(err);
  return errMsg.includes("exceeds") && errMsg.includes("MB limit");
}'''

new_fn = '''function isMediaSizeLimitError(err: unknown): boolean {
  if (err instanceof MediaFetchError && err.code === "max_bytes") {
    return true;
  }
  const errMsg = String(err);
  return errMsg.includes("exceeds") && errMsg.includes("MB limit");
}'''

if old_fn not in content:
    print(f"ERROR: Could not find isMediaSizeLimitError in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_fn, new_fn, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"Patched {filepath}")
PYEOF
  echo "$PATCH_ID: Patched $FILE2"
fi

# --- File 3: src/telegram/bot/delivery.resolve-media.ts ---
# Add pre-download size check using file_size from getFile response
# Also import MediaFetchError
FILE3="src/telegram/bot/delivery.resolve-media.ts"

if [[ ! -f "$FILE3" ]]; then
  echo "$PATCH_ID: ERROR - $FILE3 not found"
  exit 1
fi

MARKER3="file.file_size"
if grep -q "$MARKER3" "$FILE3"; then
  echo "$PATCH_ID: $FILE3 already patched (idempotent skip)"
else
  python3 - "$FILE3" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# 1. Add MediaFetchError import
old_import = 'import { fetchRemoteMedia } from "../../media/fetch.js";'
new_import = 'import { MediaFetchError, fetchRemoteMedia } from "../../media/fetch.js";'

if old_import not in content:
    print(f"ERROR: Could not find fetchRemoteMedia import in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import, new_import, 1)

# 2. Change resolveTelegramFileWithRetry return type to include file_size
# The function returns { file_path?: string } | null — we need to add file_size
old_return_type = 'Promise<{ file_path?: string } | null>'
new_return_type = 'Promise<{ file_path?: string; file_size?: number } | null>'

if old_return_type not in content:
    print(f"ERROR: Could not find resolveTelegramFileWithRetry return type in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_return_type, new_return_type, 1)

# 3. Add pre-download size check after file_path check in resolveMedia
old_check = '''  if (!file.file_path) {
    throw new Error("Telegram getFile returned no file_path");
  }
  const saved = await downloadAndSaveTelegramFile({'''

new_check = '''  if (!file.file_path) {
    throw new Error("Telegram getFile returned no file_path");
  }

  // Reject before downloading: Telegram's getFile includes file_size when known.
  if (typeof file.file_size === "number" && file.file_size > maxBytes) {
    throw new MediaFetchError("max_bytes", `File size ${file.file_size} exceeds limit ${maxBytes}`);
  }

  const saved = await downloadAndSaveTelegramFile({'''

if old_check not in content:
    print(f"ERROR: Could not find file_path check block in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_check, new_check, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"Patched {filepath}")
PYEOF
  echo "$PATCH_ID: Patched $FILE3"
fi

echo "$PATCH_ID: Done"
