#!/usr/bin/env bash
# Issue #26999: fix(typing): prevent keepalive loop restart after cleanup during async race
#
# Problem: In both typing controllers, an async await (fireStart/ensureStart)
# can resolve AFTER the typing has been stopped/sealed. Without a re-check,
# keepaliveLoop.start() or typingLoop.start() runs after cleanup, causing
# a permanent "typing..." indicator on Telegram.
#
# Fix: Add a state guard after each async await, before restarting the loop.
#
# Changes:
#   1. src/channels/typing.ts — add `if (stopSent) return;` after `await fireStart()`
#   2. src/auto-reply/reply/typing.ts — add `if (sealed || runComplete) return;` after `await ensureStart()`
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'if (stopSent)' "$SRC/channels/typing.ts" 2>/dev/null && \
   grep -B1 'if (stopSent)' "$SRC/channels/typing.ts" 2>/dev/null | grep -q 'fireStart'; then
  echo "    SKIP: #26999 already applied"
  exit 0
fi

# ── 1. src/channels/typing.ts ─────────────────────────────────────────────
python3 - "$SRC/channels/typing.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Find the pattern: await fireStart();\n    keepaliveLoop.start();
# Insert the guard between them
old = 'await fireStart();\n    keepaliveLoop.start();'
new = '''await fireStart();
    if (stopSent) {
      return;
    }
    keepaliveLoop.start();'''

if 'if (stopSent)' in content and 'fireStart' in content:
    # Check if already applied near fireStart
    idx = content.find('await fireStart()')
    if idx >= 0 and 'if (stopSent)' in content[idx:idx+100]:
        print("    SKIP: #26999 channels/typing.ts already patched")
        sys.exit(0)

if old not in content:
    # Try with different indentation (2 spaces deeper)
    for indent in ['    ', '      ', '        ']:
        variant = f'await fireStart();\\n{indent}keepaliveLoop.start();'
        if variant in content:
            new_variant = f'''await fireStart();
{indent}if (stopSent) {{
{indent}  return;
{indent}}}
{indent}keepaliveLoop.start();'''
            content = content.replace(variant, new_variant, 1)
            print("    OK: #26999 channels/typing.ts patched (variant indent)")
            break
    else:
        print("    FAIL: #26999 cannot find fireStart+keepaliveLoop pattern in channels/typing.ts", file=sys.stderr)
        sys.exit(1)
else:
    content = content.replace(old, new, 1)
    print("    OK: #26999 channels/typing.ts patched")

with open(path, 'w') as f:
    f.write(content)
PYEOF

# ── 2. src/auto-reply/reply/typing.ts ─────────────────────────────────────
python3 - "$SRC/auto-reply/reply/typing.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Find the pattern: await ensureStart();\n    typingLoop.start();
# Insert the guard between them
old = 'await ensureStart();\n    typingLoop.start();'
new = '''await ensureStart();
    if (sealed || runComplete) {
      return;
    }
    typingLoop.start();'''

if 'sealed || runComplete' in content:
    idx = content.find('await ensureStart()')
    if idx >= 0 and 'sealed || runComplete' in content[idx:idx+150]:
        print("    SKIP: #26999 auto-reply/reply/typing.ts already patched")
        sys.exit(0)

if old not in content:
    # Try with different indentation
    for indent in ['    ', '      ', '        ']:
        variant = f'await ensureStart();\\n{indent}typingLoop.start();'
        if variant in content:
            new_variant = f'''await ensureStart();
{indent}if (sealed || runComplete) {{
{indent}  return;
{indent}}}
{indent}typingLoop.start();'''
            content = content.replace(variant, new_variant, 1)
            print("    OK: #26999 auto-reply/reply/typing.ts patched (variant indent)")
            break
    else:
        print("    FAIL: #26999 cannot find ensureStart+typingLoop pattern in auto-reply/reply/typing.ts", file=sys.stderr)
        sys.exit(1)
else:
    content = content.replace(old, new, 1)
    print("    OK: #26999 auto-reply/reply/typing.ts patched")

with open(path, 'w') as f:
    f.write(content)
PYEOF

echo "    OK: #26999 fully applied"
