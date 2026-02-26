#!/usr/bin/env bash
# PR #27021: fix(typing): add keepalive failsafe timer
# Typing indicator sonsuz keepalive'a girerse 120s sonra otomatik durduruyor.
#
# BUG FIX (2026-02-26): Original PR re-arms failsafe on every onReplyStart() call.
# createTypingController's 6s typingLoop calls onReplyStart() every tick, which
# resets the 120s timer endlessly — failsafe never fires.
# Fix: if failsafe is already armed, don't re-arm. Only arm on first call.
# fireStop() clears failsafeTimer, so next fresh onReplyStart() re-arms correctly.
#
# 2 dosya: typing.ts (+30/-0), typing.test.ts (+30/-0)
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'maxKeepaliveMs' "$SRC/channels/typing.ts" 2>/dev/null; then
  echo "    SKIP: #27021 already applied"
  exit 0
fi

# ── 1. typing.ts: 5 modifications ──────────────────────────────────────────
python3 - "$SRC/channels/typing.ts" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    src = f.read()
original = src

# 1) Add maxKeepaliveMs parameter + JSDoc
old1 = """\
  keepaliveIntervalMs?: number;
}): TypingCallbacks {"""

new1 = """\
  keepaliveIntervalMs?: number;
  /**
   * Failsafe: automatically stop keepalive after this duration if no idle/cleanup arrives.
   * Prevents stuck typing indicators when a channel path misses cleanup.
   */
  maxKeepaliveMs?: number;
}): TypingCallbacks {"""

if old1 not in src:
    print("    FAIL: marker 1 (param) not found in typing.ts")
    sys.exit(1)
src = src.replace(old1, new1, 1)

# 2) Add maxKeepaliveMs const + failsafeTimer variable
old2 = """\
  const keepaliveIntervalMs = params.keepaliveIntervalMs ?? 3_000;
  let stopSent = false;"""

new2 = """\
  const keepaliveIntervalMs = params.keepaliveIntervalMs ?? 3_000;
  const maxKeepaliveMs = params.maxKeepaliveMs ?? 120_000;
  let stopSent = false;
  let failsafeTimer: ReturnType<typeof setTimeout> | undefined;"""

if old2 not in src:
    print("    FAIL: marker 2 (const) not found in typing.ts")
    sys.exit(1)
src = src.replace(old2, new2, 1)

# 3) Add armFailsafe function between keepaliveLoop and onReplyStart
old3 = """\
  });

  const onReplyStart = async () => {"""

new3 = """\
  });

  const armFailsafe = () => {
    if (maxKeepaliveMs <= 0) {
      return;
    }
    // Don't re-arm if already armed — outer typingLoop calls onReplyStart every 6s
    // which would reset the timer endlessly, making the failsafe never fire.
    if (failsafeTimer) {
      return;
    }
    failsafeTimer = setTimeout(() => {
      // Don't close the callback entirely; just stop this run's keepalive.
      keepaliveLoop.stop();
      if (!stop || stopSent) {
        return;
      }
      stopSent = true;
      void stop().catch((err) => (params.onStopError ?? params.onStartError)(err));
    }, maxKeepaliveMs);
  };

  const onReplyStart = async () => {"""

if old3 not in src:
    print("    FAIL: marker 3 (armFailsafe) not found in typing.ts")
    sys.exit(1)
src = src.replace(old3, new3, 1)

# 4a) Add armFailsafe() call in onReplyStart
old4a = """\
    await fireStart();
    keepaliveLoop.start();
  };

  const fireStop"""

new4a = """\
    await fireStart();
    keepaliveLoop.start();
    armFailsafe();
  };

  const fireStop"""

if old4a not in src:
    print("    FAIL: marker 4a (onReplyStart) not found in typing.ts")
    sys.exit(1)
src = src.replace(old4a, new4a, 1)

# 4b) Add failsafe timer cleanup in fireStop
old4b = """\
  const fireStop = () => {
    keepaliveLoop.stop();
    if (!stop || stopSent) {"""

new4b = """\
  const fireStop = () => {
    keepaliveLoop.stop();
    if (failsafeTimer) {
      clearTimeout(failsafeTimer);
      failsafeTimer = undefined;
    }
    if (!stop || stopSent) {"""

if old4b not in src:
    print("    FAIL: marker 4b (fireStop) not found in typing.ts")
    sys.exit(1)
src = src.replace(old4b, new4b, 1)

if src == original:
    print("    FAIL: no changes were made to typing.ts")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(src)
print("    OK: #27021 typing.ts patched (5 modifications)")
PYEOF

# ── 2. typing.test.ts: append failsafe test case ───────────────────────────
python3 - "$SRC/channels/typing.test.ts" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    src = f.read()
original = src

# Find last test case closure and describe closure
old = """\
    expect(stop).toHaveBeenCalledTimes(1);
  });
});"""

new_test = """\
    expect(stop).toHaveBeenCalledTimes(1);
  });

  it("auto-stops keepalive when cleanup is missed", async () => {
    vi.useFakeTimers();
    try {
      const start = vi.fn().mockResolvedValue(undefined);
      const stop = vi.fn().mockResolvedValue(undefined);
      const onStartError = vi.fn();
      const callbacks = createTypingCallbacks({
        start,
        stop,
        onStartError,
        keepaliveIntervalMs: 3_000,
        maxKeepaliveMs: 10_000,
      });

      await callbacks.onReplyStart();
      expect(start).toHaveBeenCalledTimes(1);

      await vi.advanceTimersByTimeAsync(9_000);
      expect(start).toHaveBeenCalledTimes(4); // t=0,3,6,9
      expect(stop).toHaveBeenCalledTimes(0);

      await vi.advanceTimersByTimeAsync(1_500);
      await flushMicrotasks();
      expect(stop).toHaveBeenCalledTimes(1);

      // After failsafe fires, no more keepalive ticks
      await vi.advanceTimersByTimeAsync(9_000);
      expect(start).toHaveBeenCalledTimes(4);
    } finally {
      vi.useRealTimers();
    }
  });
});"""

if old not in src:
    print("    WARN: test marker not found, skipping test file")
    sys.exit(0)

src = src.replace(old, new_test, 1)

if src == original:
    print("    WARN: no test changes made")
    sys.exit(0)

with open(path, 'w') as f:
    f.write(src)
print("    OK: #27021 typing.test.ts patched (1 test appended)")
PYEOF

echo "    OK: #27021 typing failsafe fully applied"
