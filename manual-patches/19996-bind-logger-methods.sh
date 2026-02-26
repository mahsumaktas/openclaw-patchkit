#!/usr/bin/env bash
set -euo pipefail
cd "$1"

# PR #19996 - fix(plugins): bind logger methods to preserve this context
# Changes: In src/plugins/registry.ts, the normalizeLogger function needs to
# bind each logger method to the logger instance to preserve `this` context
# for loggers like tslog that rely on internal state.
#
# Before:
#   info: logger.info,
#   warn: logger.warn,
#   error: logger.error,
#   debug: logger.debug,
#
# After:
#   info: logger.info.bind(logger),
#   warn: logger.warn.bind(logger),
#   error: logger.error.bind(logger),
#   debug: logger.debug?.bind(logger),

TARGET="src/plugins/registry.ts"

if [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET not found"
  exit 1
fi

# Idempotency check: if already bound, skip
if grep -q 'logger\.info\.bind(logger)' "$TARGET"; then
  echo "SKIP: logger methods already bound in $TARGET"
  exit 0
fi

# Verify the normalizeLogger function exists with unbound methods
if ! grep -q 'normalizeLogger' "$TARGET"; then
  echo "FAIL: normalizeLogger function not found in $TARGET"
  exit 1
fi

python3 << 'PYEOF'
import re
import sys

target = "src/plugins/registry.ts"
with open(target, "r") as f:
    content = f.read()

# Find the normalizeLogger function and bind methods
# Pattern: look for normalizeLogger that returns an object with logger.xxx properties
pattern = re.compile(
    r'(const\s+normalizeLogger\s*=\s*\(logger:\s*PluginLogger\):\s*PluginLogger\s*=>\s*\({[^}]*?)'
    r'info:\s*logger\.info,'
    r'([^}]*?)'
    r'warn:\s*logger\.warn,'
    r'([^}]*?)'
    r'error:\s*logger\.error,'
    r'([^}]*?)'
    r'debug:\s*logger\.debug,'
    r'([^}]*?\}\))',
    re.DOTALL
)

match = pattern.search(content)
if not match:
    # Try alternate: debug might not have trailing comma
    pattern2 = re.compile(
        r'(const\s+normalizeLogger\s*=\s*\(logger:\s*PluginLogger\):\s*PluginLogger\s*=>\s*\({[^}]*?)'
        r'info:\s*logger\.info,'
        r'([^}]*?)'
        r'warn:\s*logger\.warn,'
        r'([^}]*?)'
        r'error:\s*logger\.error,'
        r'([^}]*?)'
        r'debug:\s*logger\.debug\b(?![\.\?])'
        r'([^}]*?\}\))',
        re.DOTALL
    )
    match = pattern2.search(content)

if not match:
    print("FAIL: Could not find normalizeLogger with unbound logger methods", file=sys.stderr)
    sys.exit(1)

# Replace unbound with bound
new_content = content
# Do replacements within the normalizeLogger function only
# Find start/end of normalizeLogger
nl_start = content.find("const normalizeLogger")
if nl_start == -1:
    print("FAIL: normalizeLogger not found", file=sys.stderr)
    sys.exit(1)

# Find the closing of the arrow function: => ({ ... });
# Look for the next "})" after the opening "({"
brace_start = content.find("({", nl_start)
if brace_start == -1:
    print("FAIL: Could not find opening of normalizeLogger return object", file=sys.stderr)
    sys.exit(1)

# Find matching })
depth = 0
i = brace_start
while i < len(content):
    if content[i] == '(' and i + 1 < len(content) and content[i+1] == '{':
        depth += 1
        i += 2
        continue
    elif content[i] == '}' and i + 1 < len(content) and content[i+1] == ')':
        depth -= 1
        if depth == 0:
            nl_end = i + 2
            break
        i += 2
        continue
    i += 1
else:
    print("FAIL: Could not find end of normalizeLogger", file=sys.stderr)
    sys.exit(1)

func_body = content[nl_start:nl_end]

# Replace each method assignment
new_body = func_body
new_body = re.sub(r'info:\s*logger\.info\b', 'info: logger.info.bind(logger)', new_body)
new_body = re.sub(r'warn:\s*logger\.warn\b', 'warn: logger.warn.bind(logger)', new_body)
new_body = re.sub(r'error:\s*logger\.error\b', 'error: logger.error.bind(logger)', new_body)
# debug uses optional chaining: logger.debug?.bind(logger)
new_body = re.sub(r'debug:\s*logger\.debug\b', 'debug: logger.debug?.bind(logger)', new_body)

new_content = content[:nl_start] + new_body + content[nl_end:]

with open(target, "w") as f:
    f.write(new_content)

print("OK: Bound logger methods in normalizeLogger")
PYEOF

# Verify
if grep -q 'logger\.info\.bind(logger)' "$TARGET" && \
   grep -q 'logger\.warn\.bind(logger)' "$TARGET" && \
   grep -q 'logger\.error\.bind(logger)' "$TARGET" && \
   grep -q 'logger\.debug?\.bind(logger)' "$TARGET"; then
  echo "OK: PR #19996 applied successfully - logger methods bound to preserve this context"
else
  echo "FAIL: Verification failed after applying changes"
  exit 1
fi
