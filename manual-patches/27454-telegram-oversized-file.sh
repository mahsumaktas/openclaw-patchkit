#!/usr/bin/env bash
# PR #27454 — fix(telegram): prevent crash loop on oversized file attachments
# v2026.3.7: delivery.resolve-media.ts was refactored — no more inline getFile().
# resolveTelegramFileWithRetry() is now a standalone function. The pre-download
# size check goes before the resolveTelegramFileWithRetry call in the main resolve
# function, using the `m` variable from resolveMediaFileRef (has file_size).
#
# Two changes:
# 1. delivery.resolve-media.ts: Import MediaFetchError + pre-download file_size check
#    before resolveTelegramFileWithRetry() — skip download if file_size > 50MB
# 2. bot-handlers.ts: Strengthen isMediaSizeLimitError to detect MediaFetchError instances
set +e

SRC="${1:?Usage: $0 <openclaw-source-dir>}/src"

RESOLVE_MEDIA="$SRC/telegram/bot/delivery.resolve-media.ts"
HANDLERS="$SRC/telegram/bot-handlers.ts"

# ── Idempotency check ──
if grep -q 'Pre-download size check' "$RESOLVE_MEDIA" 2>/dev/null; then
  echo "    SKIP: #27454 already applied"
  exit 0
fi

[ -f "$RESOLVE_MEDIA" ] || { echo "    FAIL: $RESOLVE_MEDIA not found"; exit 1; }
[ -f "$HANDLERS" ]      || { echo "    FAIL: $HANDLERS not found"; exit 1; }

# ── 1. delivery.resolve-media.ts: Add MediaFetchError import + pre-download size check ──
python3 - "$RESOLVE_MEDIA" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changed = False

# 1a. Add MediaFetchError to the fetch.js import
if 'MediaFetchError' not in content:
    pat = re.compile(
        r'(import\s*\{[^}]*fetchRemoteMedia[^}]*\}\s*from\s*["\'][^"\']*media/fetch\.js["\'];)'
    )
    m = pat.search(content)
    if m:
        old_imp = m.group(1)
        new_imp = old_imp.replace('{ fetchRemoteMedia }', '{ fetchRemoteMedia, MediaFetchError }')
        if new_imp == old_imp:
            new_imp = old_imp.replace('fetchRemoteMedia', 'fetchRemoteMedia, MediaFetchError', 1)
        content = content.replace(old_imp, new_imp, 1)
        changed = True
        print("    OK: #27454 MediaFetchError import added to delivery.resolve-media.ts")
    else:
        print("    FAIL: #27454 fetchRemoteMedia import not found in delivery.resolve-media.ts")
        sys.exit(1)

# 1b. v2026.3.7: resolveTelegramFileWithRetry replaced inline getFile.
# Insert pre-download size check before the main resolveTelegramFileWithRetry call
# (the one after resolveMediaFileRef, around "const file = await resolveTelegramFileWithRetry").
# The `m` variable from resolveMediaFileRef has file_size metadata.
MARKER = '  const file = await resolveTelegramFileWithRetry(ctx);\n  if (!file) {\n    return null;\n  }\n  if (!file.file_path) {\n    throw new Error("Telegram getFile returned no file_path");'

SIZE_CHECK = """  // Pre-download size check: Telegram provides file_size in message metadata.
  // Bots cannot download files > 50 MB. Reject early to avoid a crash loop
  // where ctx.getFile() hangs or throws on oversized files (#27454).
  const TELEGRAM_BOT_FILE_LIMIT = 50 * 1024 * 1024; // 50 MB
  if (m && "file_size" in m && typeof m.file_size === "number" && m.file_size > TELEGRAM_BOT_FILE_LIMIT) {
    const sizeMb = (m.file_size / (1024 * 1024)).toFixed(1);
    throw new MediaFetchError(
      "max_bytes",
      `File size ${sizeMb}MB exceeds Telegram bot download limit of 50MB`,
    );
  }

"""

if 'Pre-download size check' not in content:
    if MARKER in content:
        content = content.replace(MARKER, SIZE_CHECK + MARKER, 1)
        changed = True
        print("    OK: #27454 pre-download size check added to delivery.resolve-media.ts")
    else:
        # Fallback: try a simpler marker
        simple_marker = '  const file = await resolveTelegramFileWithRetry(ctx);\n  if (!file) {'
        if simple_marker in content:
            content = content.replace(simple_marker, SIZE_CHECK + simple_marker, 1)
            changed = True
            print("    OK: #27454 pre-download size check added (simple marker) to delivery.resolve-media.ts")
        else:
            print("    FAIL: #27454 resolveTelegramFileWithRetry marker not found in delivery.resolve-media.ts")
            sys.exit(1)

if changed:
    with open(path, 'w') as f:
        f.write(content)
else:
    print("    SKIP: #27454 delivery.resolve-media.ts already has all changes")
PYEOF

if [ $? -ne 0 ]; then
  echo "    FAIL: Could not patch delivery.resolve-media.ts"
  exit 1
fi

# ── 2. bot-handlers.ts: Strengthen isMediaSizeLimitError ──
python3 - "$HANDLERS" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# v2026.3.7: MediaFetchError is already imported in bot-handlers.ts
# isMediaSizeLimitError currently only checks string patterns.
# isRecoverableMediaGroupError already uses MediaFetchError instanceof check.
# Add MediaFetchError instanceof check to isMediaSizeLimitError too.
OLD_CHECK = 'function isMediaSizeLimitError(err: unknown): boolean {\n  const errMsg = String(err);\n  return errMsg.includes("exceeds") && errMsg.includes("MB limit");\n}'

NEW_CHECK = '''function isMediaSizeLimitError(err: unknown): boolean {
  if (err instanceof MediaFetchError && err.code === "max_bytes") {
    return true;
  }
  const errMsg = String(err);
  return errMsg.includes("exceeds") && (errMsg.includes("MB limit") || errMsg.includes("maxBytes"));
}'''

if 'err instanceof MediaFetchError && err.code === "max_bytes"' in content:
    print("    SKIP: #27454 bot-handlers.ts already patched")
else:
    if OLD_CHECK in content:
        content = content.replace(OLD_CHECK, NEW_CHECK, 1)
        with open(path, 'w') as f:
            f.write(content)
        print("    OK: #27454 isMediaSizeLimitError strengthened in bot-handlers.ts")
    else:
        # Try relaxed match
        import re
        pat = re.compile(
            r'function isMediaSizeLimitError\(err:\s*unknown\):\s*boolean\s*\{[^}]+\}',
            re.DOTALL,
        )
        m = pat.search(content)
        if m:
            content = content[:m.start()] + NEW_CHECK + content[m.end():]
            with open(path, 'w') as f:
                f.write(content)
            print("    OK: #27454 isMediaSizeLimitError replaced (relaxed match) in bot-handlers.ts")
        else:
            print("    WARN: #27454 isMediaSizeLimitError not found in bot-handlers.ts — may need manual review")
PYEOF

echo "    DONE: 27454-telegram-oversized-file applied"
