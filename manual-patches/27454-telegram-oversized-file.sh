#!/usr/bin/env bash
# PR #27454 — fix(telegram): prevent crash loop on oversized file attachments
# Two changes:
# 1. delivery.ts: Pre-download size check using file_size metadata + import MediaFetchError
# 2. bot-handlers.ts: Strengthen isMediaSizeLimitError to detect MediaFetchError instances
# NOTE: PR diff omits the MediaFetchError import — we add it manually.
set -euo pipefail

SRC="${1:?Usage: $0 <openclaw-source-dir>}/src"
DELIVERY="$SRC/telegram/bot/delivery.ts"
HANDLERS="$SRC/telegram/bot-handlers.ts"

# ── Idempotency check ──
if grep -q 'Pre-download size check' "$DELIVERY" 2>/dev/null; then
  echo "    SKIP: #27454 already applied"
  exit 0
fi

[ -f "$DELIVERY" ] || { echo "    FAIL: $DELIVERY not found"; exit 1; }
[ -f "$HANDLERS" ] || { echo "    FAIL: $HANDLERS not found"; exit 1; }

# ── 1. delivery.ts: Add MediaFetchError import + pre-download size check ──
python3 - "$DELIVERY" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1a. Add MediaFetchError to the fetch.js import
if 'MediaFetchError' not in content:
    old_import = 'import { fetchRemoteMedia } from "../../media/fetch.js";'
    new_import = 'import { fetchRemoteMedia, MediaFetchError } from "../../media/fetch.js";'
    if old_import in content:
        content = content.replace(old_import, new_import, 1)
        print("    OK: #27454 MediaFetchError import added to delivery.ts")
    else:
        # Try alternate import path
        import re
        m = re.search(r'import \{ fetchRemoteMedia \} from ["\']([^"\']+)["\'];', content)
        if m:
            old = m.group(0)
            new = old.replace('{ fetchRemoteMedia }', '{ fetchRemoteMedia, MediaFetchError }')
            content = content.replace(old, new, 1)
            print("    OK: #27454 MediaFetchError import added (alt path)")
        else:
            print("    FAIL: #27454 fetchRemoteMedia import not found")
            sys.exit(1)

# 1b. Add pre-download size check before the ctx.getFile() call
old_block = '  let file: { file_path?: string };\n  try {\n    file = await retryAsync(() => ctx.getFile(), {'
new_block = '''  // Pre-download size check: Telegram provides file_size in the message metadata.
  // Reject early to avoid downloading large files we'll discard anyway (#26246).
  if (maxBytes && "file_size" in m && typeof m.file_size === "number" && m.file_size > maxBytes) {
    const sizeMb = (m.file_size / (1024 * 1024)).toFixed(1);
    const limitMb = (maxBytes / (1024 * 1024)).toFixed(0);
    throw new MediaFetchError(
      "max_bytes",
      `File size ${sizeMb}MB exceeds maxBytes limit of ${limitMb}MB`,
    );
  }

  let file: { file_path?: string };
  try {
    file = await retryAsync(() => ctx.getFile(), {'''

if 'Pre-download size check' not in content:
    if old_block in content:
        content = content.replace(old_block, new_block, 1)
        print("    OK: #27454 pre-download size check added to delivery.ts")
    else:
        print("    FAIL: #27454 ctx.getFile() marker not found in delivery.ts")
        sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
PYEOF

if [ $? -ne 0 ]; then
  echo "    FAIL: Could not patch delivery.ts"
  exit 1
fi

# ── 2. bot-handlers.ts: Strengthen isMediaSizeLimitError ──
python3 - "$HANDLERS" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Check if MediaFetchError is imported
if 'MediaFetchError' not in content:
    # Add import — find the media/fetch import or add near top
    import re
    m = re.search(r'(import \{[^}]*\} from ["\'].*?/media/fetch\.js["\'];)', content)
    if m:
        old = m.group(1)
        if 'MediaFetchError' not in old:
            new = old.replace('{ ', '{ MediaFetchError, ')
            content = content.replace(old, new, 1)
            print("    OK: #27454 MediaFetchError import added to bot-handlers.ts")
    else:
        # Add a new import line after the last import
        last_import = content.rfind('\nimport ')
        if last_import >= 0:
            end_of_line = content.index('\n', last_import + 1)
            content = content[:end_of_line+1] + 'import { MediaFetchError } from "./bot/media-fetch.js";\n' + content[end_of_line+1:]
            print("    WARN: #27454 MediaFetchError import added with guessed path — may need review")

old_check = 'function isMediaSizeLimitError(err: unknown): boolean {\n  const errMsg = String(err);\n  return errMsg.includes("exceeds") && errMsg.includes("MB limit");\n}'

new_check = '''function isMediaSizeLimitError(err: unknown): boolean {
  if (err instanceof MediaFetchError && err.code === "max_bytes") {
    return true;
  }
  const errMsg = String(err);
  return errMsg.includes("exceeds") && (errMsg.includes("MB limit") || errMsg.includes("maxBytes"));
}'''

if 'err instanceof MediaFetchError' in content:
    print("    SKIP: #27454 bot-handlers.ts already patched")
else:
    if old_check in content:
        content = content.replace(old_check, new_check, 1)
        with open(path, 'w') as f:
            f.write(content)
        print("    OK: #27454 bot-handlers.ts patched")
    else:
        print("    WARN: #27454 isMediaSizeLimitError pattern not found — may already be modified")
PYEOF

echo "    DONE: 27454-telegram-oversized-file applied"
