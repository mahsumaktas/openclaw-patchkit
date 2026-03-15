#!/usr/bin/env bash
set -euo pipefail
# PR #36588 — fix: suppress undici TLS session null-deref as transient uncaughtException
# Adds isTlsSocketNullDeref() to unhandled-rejections.ts and wires it into
# isTransientNetworkError(). Also adds transient-error guard to uncaughtException
# handlers in run-main.ts and index.ts so the gateway survives the crash.
#
# v2026.3.13 fix: run-main.ts uncaughtException handler is on a single line
# (not multi-line like old script assumed). index.ts handler is also single-line.
# The import in both files is already single-line:
#   import { installUnhandledRejectionHandler } from "...unhandled-rejections.js";
# We need to expand it to include isTransientNetworkError.
#
# Also, the candidate type-guard in isTransientNetworkError changed position:
# In v2026.3.13, the !candidate check comes AFTER name/code checks, not before.

SRC="${1:-.}/src"

REJECTIONS="$SRC/infra/unhandled-rejections.ts"
RUN_MAIN="$SRC/cli/run-main.ts"
INDEX="$SRC/index.ts"

# -- Idempotency --
if grep -q 'isTlsSocketNullDeref' "$REJECTIONS" 2>/dev/null; then
  echo "    SKIP: #36588 already applied"
  exit 0
fi

# -- File checks --
for f in "$REJECTIONS" "$RUN_MAIN" "$INDEX"; do
  if [ ! -f "$f" ]; then
    echo "    FAIL: #36588 $(basename "$f") not found"
    exit 1
  fi
done

# -- 1. Add isTlsSocketNullDeref function + wire into isTransientNetworkError --
python3 - "$REJECTIONS" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1a. Insert isTlsSocketNullDeref after the TRANSIENT_NETWORK_MESSAGE_SNIPPETS array closing
# In v2026.3.13, the array ends with:
#   "write eproto",
# ];
# followed by: function isWrappedFetchFailedMessage

anchor = 'function isWrappedFetchFailedMessage'
if anchor not in content:
    print("    FAIL: #36588 cannot find isWrappedFetchFailedMessage anchor")
    sys.exit(1)

new_function = '''/**
 * Detects the undici TLS session null-dereference crash that occurs when undici's
 * reconnect path calls tls.connect() with a stale WeakRef-cached session whose
 * internal _handle has already been destroyed.
 *
 * Stack: TLSSocket.setSession (node:_tls_wrap) <- Object.connect <- undici connect.js
 *
 * This is a transient condition -- the session cache entry becomes invalid after
 * a socket close under concurrent load; the next request will succeed without
 * a cached session. Exiting the process is unnecessary and causes crash-loops
 * when the network is still unstable at restart.
 */
export function isTlsSocketNullDeref(err: unknown): boolean {
  if (!(err instanceof TypeError)) {
    return false;
  }
  const msg = err.message ?? "";
  // Node 18+: "Cannot read properties of null (reading 'setSession')"
  // Node <18:  "Cannot read property 'setSession' of null"
  if (!msg.includes("setSession")) {
    return false;
  }
  const stack = err.stack ?? "";
  return stack.includes("TLSSocket.setSession") || stack.includes("node:_tls_wrap");
}

'''

content = content.replace(anchor, new_function + anchor, 1)

# 1b. Wire isTlsSocketNullDeref into isTransientNetworkError
# In v2026.3.13, the candidate type check is:
#     if (!candidate || typeof candidate !== "object") {
#       continue;
#     }
# We insert the TLS check just before this guard.
wire_anchor = '    if (!candidate || typeof candidate !== "object") {\n      continue;\n    }'
if wire_anchor not in content:
    # Try with double quotes (already double in source)
    print("    FAIL: #36588 cannot find candidate type-guard in isTransientNetworkError")
    sys.exit(1)

tls_check = '''    // undici TLS session null dereference during socket reconnect -- transient
    if (isTlsSocketNullDeref(candidate)) {
      return true;
    }

'''
content = content.replace(wire_anchor, tls_check + wire_anchor, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #36588 unhandled-rejections.ts — isTlsSocketNullDeref added + wired")
PYEOF

# -- 2. Add isTransientNetworkError import + uncaughtException guard to run-main.ts --
python3 - "$RUN_MAIN" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 2a. Expand import to include isTransientNetworkError
old_import = 'import { installUnhandledRejectionHandler } from "../infra/unhandled-rejections.js";'
new_import = '''import {
  installUnhandledRejectionHandler,
  isTransientNetworkError,
} from "../infra/unhandled-rejections.js";'''

if old_import in content:
    content = content.replace(old_import, new_import, 1)
elif 'isTransientNetworkError' in content:
    pass  # Already imported
else:
    print("    FAIL: #36588 cannot find unhandled-rejections import in run-main.ts")
    sys.exit(1)

# 2b. Add transient error guard to uncaughtException handler
# v2026.3.13 format (single line):
#   process.on("uncaughtException", (error) => {
#     console.error("[openclaw] Uncaught exception:", formatUncaughtError(error));
#     process.exit(1);
#   });
old_handler = '''    process.on("uncaughtException", (error) => {
      console.error("[openclaw] Uncaught exception:", formatUncaughtError(error));
      process.exit(1);
    });'''

new_handler = '''    process.on("uncaughtException", (error) => {
      // Transient network errors (e.g. undici TLS session null-deref on reconnect)
      // should not take down the gateway -- log and continue.
      if (isTransientNetworkError(error)) {
        console.warn(
          "[openclaw] Suppressed transient uncaught exception:",
          formatUncaughtError(error),
        );
        process.exitCode = 1;
        return;
      }
      console.error("[openclaw] Uncaught exception:", formatUncaughtError(error));
      process.exit(1);
    });'''

if old_handler in content:
    content = content.replace(old_handler, new_handler, 1)
elif 'Suppressed transient uncaught exception' in content:
    pass  # Already patched
else:
    # Try flexible whitespace matching
    import re
    pattern = r'(process\.on\("uncaughtException", \(error\) => \{)\s*(console\.error\("\[openclaw\] Uncaught exception:", formatUncaughtError\(error\)\);)\s*(process\.exit\(1\);)\s*(\}\);)'
    m = re.search(pattern, content)
    if m:
        indent = "    "
        # Detect actual indentation from the match
        line_start = content.rfind('\n', 0, m.start()) + 1
        indent = content[line_start:m.start()]
        inner = indent + "  "
        replacement = (
            m.group(1) + "\n"
            + inner + "// Transient network errors (e.g. undici TLS session null-deref on reconnect)\n"
            + inner + "// should not take down the gateway -- log and continue.\n"
            + inner + "if (isTransientNetworkError(error)) {\n"
            + inner + "  console.warn(\n"
            + inner + '    "[openclaw] Suppressed transient uncaught exception:",\n'
            + inner + "    formatUncaughtError(error),\n"
            + inner + "  );\n"
            + inner + "  process.exitCode = 1;\n"
            + inner + "  return;\n"
            + inner + "}\n"
            + inner + m.group(2) + "\n"
            + inner + m.group(3) + "\n"
            + indent + m.group(4)
        )
        content = content[:m.start()] + replacement + content[m.end():]
    else:
        print("    FAIL: #36588 cannot find uncaughtException handler in run-main.ts")
        sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #36588 run-main.ts — transient error guard added")
PYEOF

# -- 3. Add isTransientNetworkError import + uncaughtException guard to index.ts --
python3 - "$INDEX" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 3a. Expand import to include isTransientNetworkError
old_import = 'import { installUnhandledRejectionHandler } from "./infra/unhandled-rejections.js";'
new_import = '''import {
  installUnhandledRejectionHandler,
  isTransientNetworkError,
} from "./infra/unhandled-rejections.js";'''

if old_import in content:
    content = content.replace(old_import, new_import, 1)
elif 'isTransientNetworkError' in content:
    pass
else:
    print("    FAIL: #36588 cannot find unhandled-rejections import in index.ts")
    sys.exit(1)

# 3b. Add transient error guard to uncaughtException handler
# v2026.3.13: indentation is 2 spaces (top-level if block)
old_handler = '''  process.on("uncaughtException", (error) => {
    console.error("[openclaw] Uncaught exception:", formatUncaughtError(error));
    process.exit(1);
  });'''

new_handler = '''  process.on("uncaughtException", (error) => {
    // Transient network errors (e.g. undici TLS session null-deref on reconnect)
    // should not take down the gateway -- log and continue.
    if (isTransientNetworkError(error)) {
      console.warn(
        "[openclaw] Suppressed transient uncaught exception:",
        formatUncaughtError(error),
      );
      process.exitCode = 1;
      return;
    }
    console.error("[openclaw] Uncaught exception:", formatUncaughtError(error));
    process.exit(1);
  });'''

if old_handler in content:
    content = content.replace(old_handler, new_handler, 1)
elif 'Suppressed transient uncaught exception' in content:
    pass
else:
    # Flexible whitespace fallback
    import re
    pattern = r'(process\.on\("uncaughtException", \(error\) => \{)\s*(console\.error\("\[openclaw\] Uncaught exception:", formatUncaughtError\(error\)\);)\s*(process\.exit\(1\);)\s*(\}\);)'
    m = re.search(pattern, content)
    if m:
        line_start = content.rfind('\n', 0, m.start()) + 1
        indent = content[line_start:m.start()]
        inner = indent + "  "
        replacement = (
            m.group(1) + "\n"
            + inner + "// Transient network errors (e.g. undici TLS session null-deref on reconnect)\n"
            + inner + "// should not take down the gateway -- log and continue.\n"
            + inner + "if (isTransientNetworkError(error)) {\n"
            + inner + "  console.warn(\n"
            + inner + '    "[openclaw] Suppressed transient uncaught exception:",\n'
            + inner + "    formatUncaughtError(error),\n"
            + inner + "  );\n"
            + inner + "  process.exitCode = 1;\n"
            + inner + "  return;\n"
            + inner + "}\n"
            + inner + m.group(2) + "\n"
            + inner + m.group(3) + "\n"
            + indent + m.group(4)
        )
        content = content[:m.start()] + replacement + content[m.end():]
    else:
        print("    FAIL: #36588 cannot find uncaughtException handler in index.ts")
        sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #36588 index.ts — transient error guard added")
PYEOF

echo "    OK: #36588 undici TLS null-deref crash prevention fully applied"
