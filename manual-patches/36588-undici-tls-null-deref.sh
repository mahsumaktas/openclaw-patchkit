#!/usr/bin/env bash
set -euo pipefail
# PR #36588 — fix: prevent undici TLS session null-deref crash
# Adds isTlsSocketNullDeref() to unhandled-rejections.ts and wires it into
# isTransientNetworkError(). Also adds transient-error guard to uncaughtException
# handlers in run-main.ts and index.ts so the gateway survives the crash.

SRC="${1:-.}/src"

REJECTIONS="$SRC/infra/unhandled-rejections.ts"
RUN_MAIN="$SRC/cli/run-main.ts"
INDEX="$SRC/index.ts"

# ── Idempotency ──
if grep -q 'isTlsSocketNullDeref' "$REJECTIONS" 2>/dev/null; then
  echo "    SKIP: #36588 already applied"
  exit 0
fi

# ── File checks ──
for f in "$REJECTIONS" "$RUN_MAIN" "$INDEX"; do
  if [ ! -f "$f" ]; then
    echo "    FAIL: $(basename "$f") not found"
    exit 1
  fi
done

# ── 1. Add isTlsSocketNullDeref function to unhandled-rejections.ts ──
python3 - "$REJECTIONS" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Insert the isTlsSocketNullDeref function right after the TRANSIENT_NETWORK_MESSAGE_SNIPPETS array
anchor = '"temporary failure in name resolution",'
if anchor not in content:
    # Try without trailing comma (in case formatting differs)
    anchor = '"temporary failure in name resolution"'
if anchor not in content:
    print("    FAIL: cannot find TRANSIENT_NETWORK_MESSAGE_SNIPPETS anchor")
    sys.exit(1)

# Find the end of the array (the ]; line after the anchor)
idx = content.index(anchor)
bracket_idx = content.index('];', idx)
insert_point = content.index('\n', bracket_idx) + 1

new_function = '''
/**
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

content = content[:insert_point] + new_function + content[insert_point:]

# Now wire isTlsSocketNullDeref into isTransientNetworkError
# Find the right insertion point: after the existing transient checks, before the
# "if (!candidate || typeof candidate !== 'object')" guard
wire_anchor = '    if (!candidate || typeof candidate !== "object") {\n      continue;\n    }'
if wire_anchor not in content:
    # Try single-quoted variant
    wire_anchor = "    if (!candidate || typeof candidate !== 'object') {\n      continue;\n    }"

if wire_anchor in content:
    tls_check = '''    // undici TLS session null dereference during socket reconnect — transient
    if (isTlsSocketNullDeref(candidate)) {
      return true;
    }

'''
    content = content.replace(wire_anchor, tls_check + wire_anchor, 1)
else:
    print("    FAIL: cannot find candidate type-guard in isTransientNetworkError")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: unhandled-rejections.ts — isTlsSocketNullDeref added + wired")
PYEOF

# ── 2. Add isTransientNetworkError import + uncaughtException guard to run-main.ts ──
python3 - "$RUN_MAIN" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 2a. Update import to include isTransientNetworkError
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
    print("    FAIL: cannot find unhandled-rejections import in run-main.ts")
    sys.exit(1)

# 2b. Add transient error guard to uncaughtException handler
old_handler = '  process.on("uncaughtException", (error) => {\n    console.error("[openclaw] Uncaught exception:", formatUncaughtError(error));'
new_handler = '''  process.on("uncaughtException", (error) => {
    // Transient network errors (e.g. undici TLS session null-deref on reconnect)
    // should not take down the gateway — log and continue.
    if (isTransientNetworkError(error)) {
      console.warn(
        "[openclaw] Suppressed transient uncaught exception:",
        formatUncaughtError(error),
      );
      // Ensure one-shot CLI commands still surface a non-zero status if the
      // event loop drains; long-running gateway processes keep running normally.
      process.exitCode = 1;
      return;
    }
    console.error("[openclaw] Uncaught exception:", formatUncaughtError(error));'''

if old_handler in content:
    content = content.replace(old_handler, new_handler, 1)
elif 'Suppressed transient uncaught exception' in content:
    pass  # Already patched
else:
    print("    FAIL: cannot find uncaughtException handler in run-main.ts")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: run-main.ts — transient error guard added")
PYEOF

# ── 3. Add isTransientNetworkError import + uncaughtException guard to index.ts ──
python3 - "$INDEX" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 3a. Update import to include isTransientNetworkError
old_import = 'import { installUnhandledRejectionHandler } from "./infra/unhandled-rejections.js";'
new_import = '''import {
  installUnhandledRejectionHandler,
  isTransientNetworkError,
} from "./infra/unhandled-rejections.js";'''

if old_import in content:
    content = content.replace(old_import, new_import, 1)
elif 'isTransientNetworkError' in content:
    pass  # Already imported
else:
    print("    FAIL: cannot find unhandled-rejections import in index.ts")
    sys.exit(1)

# 3b. Add transient error guard to uncaughtException handler
old_handler = '  process.on("uncaughtException", (error) => {\n    console.error("[openclaw] Uncaught exception:", formatUncaughtError(error));'
new_handler = '''  process.on("uncaughtException", (error) => {
    // Transient network errors (e.g. undici TLS session null-deref on reconnect)
    // should not take down the gateway — log and continue.
    if (isTransientNetworkError(error)) {
      console.warn(
        "[openclaw] Suppressed transient uncaught exception:",
        formatUncaughtError(error),
      );
      // Ensure one-shot CLI commands still surface a non-zero status if the
      // event loop drains; long-running gateway processes keep running normally.
      process.exitCode = 1;
      return;
    }
    console.error("[openclaw] Uncaught exception:", formatUncaughtError(error));'''

if old_handler in content:
    content = content.replace(old_handler, new_handler, 1)
elif 'Suppressed transient uncaught exception' in content:
    pass  # Already patched
else:
    print("    FAIL: cannot find uncaughtException handler in index.ts")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: index.ts — transient error guard added")
PYEOF

echo "    OK: #36588 undici TLS null-deref crash prevention fully applied"
