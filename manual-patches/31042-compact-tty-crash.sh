#!/usr/bin/env bash
set -euo pipefail
cd "$1"

# PR #31042 — Prevent /compact from crashing terminal
# Three fixes:
# 1. tui-command-handlers.ts: Add dedicated /compact case with "compacting..." status
# 2. tui.ts: Add forceRestoreTty() function for last-resort TTY cleanup
# 3. tui.ts: Wrap tui.stop() in try/finally in requestExit + add process.once("exit") safety-net

FILE_HANDLERS="src/tui/tui-command-handlers.ts"
FILE_TUI="src/tui/tui.ts"

if [[ ! -f "$FILE_HANDLERS" ]]; then
  echo "SKIP #31042: $FILE_HANDLERS not found"
  exit 0
fi
if [[ ! -f "$FILE_TUI" ]]; then
  echo "SKIP #31042: $FILE_TUI not found"
  exit 0
fi

# Idempotency
if grep -q 'case "compact"' "$FILE_HANDLERS" 2>/dev/null && grep -q 'forceRestoreTty' "$FILE_TUI" 2>/dev/null; then
  echo "SKIP #31042: already patched"
  exit 0
fi

# --- PART 1: tui-command-handlers.ts — add /compact case ---
python3 - "$FILE_HANDLERS" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

if 'case "compact"' in content:
    print(f"SKIP #31042 part 1: /compact case already exists in {filepath}")
    sys.exit(0)

# Insert compact case before exit/quit case
old = '''      case "exit":
      case "quit":
        requestExit();
        break;'''

new = '''      case "compact":
        // Forward /compact to the gateway as a control command.
        // Show an explicit activity status while the (potentially long-running)
        // compaction is in progress so the user knows the TUI hasn't frozen.
        setActivityStatus("compacting\u2026");
        tui.requestRender();
        await sendMessage(raw);
        break;
      case "exit":
      case "quit":
        requestExit();
        break;'''

if old not in content:
    print(f"FAIL #31042 part 1: could not find exit/quit case in {filepath}")
    sys.exit(1)

content = content.replace(old, new, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"OK #31042 part 1: added /compact case to {filepath}")
PYEOF

# --- PART 2: tui.ts — add forceRestoreTty function ---
python3 - "$FILE_TUI" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

if 'forceRestoreTty' in content:
    print(f"SKIP #31042 part 2: forceRestoreTty already exists in {filepath}")
else:
    # Insert forceRestoreTty before the CtrlCAction type definition
    # v2026.3.2 has stopTuiSafely function ending, then CtrlCAction type
    old_anchor = 'type CtrlCAction = "clear" | "warn" | "exit";'

    new_block = '''/**
 * Best-effort last-resort TTY cleanup.  Called from the process 'exit'
 * safety-net and from error-path shutdowns so the parent shell is never left
 * with a corrupted raw-mode terminal (issue #30421).
 */
export function forceRestoreTty(): void {
  try {
    if (process.stdin.isTTY && typeof process.stdin.setRawMode === "function") {
      process.stdin.setRawMode(false);
    }
  } catch {
    // nothing we can do
  }
  try {
    // Re-enable cursor and disable bracketed-paste in case tui.stop() was
    // interrupted before writing these sequences.
    process.stdout.write("\\x1b[?25h\\x1b[?2004l");
  } catch {
    // nothing we can do
  }
}

type CtrlCAction = "clear" | "warn" | "exit";'''

    if old_anchor not in content:
        print(f"FAIL #31042 part 2: could not find CtrlCAction type in {filepath}")
        sys.exit(1)

    content = content.replace(old_anchor, new_block, 1)

# --- PART 3: Wrap tui.stop() in try/finally in requestExit ---
# v2026.3.2 has:
#   stopTuiSafely(() => tui.stop());
#   process.exit(0);
old_exit = '''    stopTuiSafely(() => tui.stop());
    process.exit(0);'''

new_exit = '''    try {
      stopTuiSafely(() => tui.stop());
    } finally {
      // Guarantee process.exit(0) is always reached \u2014 even when tui.stop()
      // throws \u2014 so the process never hangs and the parent shell is not left
      // with a corrupted raw-mode terminal (#30421).
      process.exit(0);
    }'''

if old_exit in content:
    content = content.replace(old_exit, new_exit, 1)
elif 'try {' in content and 'stopTuiSafely' in content:
    print("INFO #31042 part 3: try/finally already present around tui.stop()")
else:
    print(f"FAIL #31042 part 3: could not find stopTuiSafely/process.exit block in {filepath}")
    sys.exit(1)

# --- PART 4: Add process.once("exit") safety-net before SIGINT/SIGTERM handlers ---
# v2026.3.2 has:
#   process.on("SIGINT", sigintHandler);
#   process.on("SIGTERM", sigtermHandler);
old_signals = '''  process.on("SIGINT", sigintHandler);
  process.on("SIGTERM", sigtermHandler);'''

new_signals = '''  // Safety-net: ensure the terminal is always restored to a usable state even
  // when the process exits unexpectedly (uncaught exception, unhandled promise
  // rejection, SIGTERM received while /compact is running, etc.).
  const tuiExitCleanup = () => {
    forceRestoreTty();
  };
  process.once("exit", tuiExitCleanup);

  process.on("SIGINT", sigintHandler);
  process.on("SIGTERM", sigtermHandler);'''

if old_signals in content:
    content = content.replace(old_signals, new_signals, 1)
elif 'tuiExitCleanup' in content:
    print("INFO #31042 part 4: tuiExitCleanup already present")
else:
    print(f"FAIL #31042 part 4: could not find SIGINT/SIGTERM handlers in {filepath}")
    sys.exit(1)

# --- PART 5: Add cleanup removal in the finish function ---
# v2026.3.2 has:
#     const finish = () => {
#       process.removeListener("SIGINT", sigintHandler);
#       process.removeListener("SIGTERM", sigtermHandler);
#       resolve();
#     };
old_finish = '''    const finish = () => {
      process.removeListener("SIGINT", sigintHandler);
      process.removeListener("SIGTERM", sigtermHandler);
      resolve();
    };'''

new_finish = '''    const finish = () => {
      process.removeListener("SIGINT", sigintHandler);
      process.removeListener("SIGTERM", sigtermHandler);
      process.removeListener("exit", tuiExitCleanup);
      resolve();
    };'''

if old_finish in content:
    content = content.replace(old_finish, new_finish, 1)
elif 'removeListener("exit", tuiExitCleanup)' in content:
    print("INFO #31042 part 5: exit cleanup removal already present")
else:
    print(f"FAIL #31042 part 5: could not find finish() function in {filepath}")
    sys.exit(1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"OK #31042 parts 2-5: added forceRestoreTty + safety-net to {filepath}")
PYEOF
