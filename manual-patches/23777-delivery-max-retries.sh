#!/usr/bin/env bash
# Issue #23777: fix(delivery): move entries to failed/ when max retries exceeded or permanent error
#
# Problem: failDelivery() only increments retryCount but never checks MAX_RETRIES
# or permanent error patterns. Entries stay in the active queue indefinitely and
# are only triaged during gateway-restart recovery. If recovery time-budget is
# exceeded, the same stale entries roll forward on every restart.
#
# Fix: After incrementing retryCount, check if the entry should be moved to
# failed/ (max retries exceeded OR permanent error detected). This ensures
# entries are retired promptly during normal operation, not just during recovery.
#
# Changes:
#   1. src/infra/outbound/delivery-queue.ts — failDelivery() now auto-moves
#      entries to failed/ when retryCount >= MAX_RETRIES or error is permanent
set -euo pipefail

SRC="${1:-.}/src"
FILE="$SRC/infra/outbound/delivery-queue.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

# ── Idempotency gate ─────────────────────────────────────────────────────────
if grep -q 'isPermanentDeliveryError(error)' "$FILE" 2>/dev/null; then
  # Check specifically if failDelivery already references isPermanentDeliveryError
  if grep -A5 'export async function failDelivery' "$FILE" | grep -q 'isPermanentDeliveryError'; then
    echo "    SKIP: #23777 already applied"
    exit 0
  fi
fi

if grep -q 'auto-move to failed/ on max retries or permanent error' "$FILE" 2>/dev/null; then
  echo "    SKIP: #23777 already applied"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, "r") as f:
    code = f.read()

# Verify required symbols exist
for sym in ['MAX_RETRIES', 'isPermanentDeliveryError', 'moveToFailed']:
    if sym not in code:
        print(f"    FAIL: #23777 {sym} not found in delivery-queue.ts", file=sys.stderr)
        sys.exit(1)

# ── Replace failDelivery to add max-retry and permanent-error auto-move ──────
# Dual-pattern: virgin source OR post-#23672 (try-catch wrapped readFile+JSON.parse)

# Pattern A: virgin v2026.3.1 source
old_virgin = """/** Update a queue entry after a failed delivery attempt. */
export async function failDelivery(id: string, error: string, stateDir?: string): Promise<void> {
  const filePath = path.join(resolveQueueDir(stateDir), `${id}.json`);
  const raw = await fs.promises.readFile(filePath, "utf-8");
  const entry: QueuedDelivery = JSON.parse(raw);
  entry.retryCount += 1;
  entry.lastAttemptAt = Date.now();
  entry.lastError = error;
  const tmp = `${filePath}.${process.pid}.tmp`;
  await fs.promises.writeFile(tmp, JSON.stringify(entry, null, 2), {
    encoding: "utf-8",
    mode: 0o600,
  });
  await fs.promises.rename(tmp, filePath);
}"""

# Pattern B: post-#23672 (try-catch wrapped readFile+JSON.parse)
old_post23672 = """/** Update a queue entry after a failed delivery attempt. */
export async function failDelivery(id: string, error: string, stateDir?: string): Promise<void> {
  const filePath = path.join(resolveQueueDir(stateDir), `${id}.json`);
  let entry: QueuedDelivery;
  try {
    const raw = await fs.promises.readFile(filePath, "utf-8");
    entry = JSON.parse(raw);
  } catch {
    return; // File missing or corrupted — skip update
  }
  entry.retryCount += 1;
  entry.lastAttemptAt = Date.now();
  entry.lastError = error;
  const tmp = `${filePath}.${process.pid}.tmp`;
  await fs.promises.writeFile(tmp, JSON.stringify(entry, null, 2), {
    encoding: "utf-8",
    mode: 0o600,
  });
  await fs.promises.rename(tmp, filePath);
}"""

# Replacement for virgin source (no try-catch)
new_virgin = """/** Update a queue entry after a failed delivery attempt.
 *
 * If the entry has exceeded MAX_RETRIES or the error matches a known permanent
 * failure pattern, the entry is auto-moved to failed/ so it stops being retried
 * during normal operation — not just during gateway-restart recovery.
 * @see https://github.com/openclaw/openclaw/issues/23777
 */
export async function failDelivery(id: string, error: string, stateDir?: string): Promise<void> {
  const filePath = path.join(resolveQueueDir(stateDir), `${id}.json`);
  const raw = await fs.promises.readFile(filePath, "utf-8");
  const entry: QueuedDelivery = JSON.parse(raw);
  entry.retryCount += 1;
  entry.lastAttemptAt = Date.now();
  entry.lastError = error;

  // auto-move to failed/ on max retries or permanent error (#23777)
  if (entry.retryCount >= MAX_RETRIES || isPermanentDeliveryError(error)) {
    // Persist updated entry first (retryCount + lastError for audit trail)
    const tmp = `${filePath}.${process.pid}.tmp`;
    await fs.promises.writeFile(tmp, JSON.stringify(entry, null, 2), {
      encoding: "utf-8",
      mode: 0o600,
    });
    await fs.promises.rename(tmp, filePath);
    // Move to failed/ subdirectory
    await moveToFailed(id, stateDir);
    return;
  }

  const tmp = `${filePath}.${process.pid}.tmp`;
  await fs.promises.writeFile(tmp, JSON.stringify(entry, null, 2), {
    encoding: "utf-8",
    mode: 0o600,
  });
  await fs.promises.rename(tmp, filePath);
}"""

# Replacement for post-#23672 (preserves try-catch from #23672)
new_post23672 = """/** Update a queue entry after a failed delivery attempt.
 *
 * If the entry has exceeded MAX_RETRIES or the error matches a known permanent
 * failure pattern, the entry is auto-moved to failed/ so it stops being retried
 * during normal operation — not just during gateway-restart recovery.
 * @see https://github.com/openclaw/openclaw/issues/23777
 */
export async function failDelivery(id: string, error: string, stateDir?: string): Promise<void> {
  const filePath = path.join(resolveQueueDir(stateDir), `${id}.json`);
  let entry: QueuedDelivery;
  try {
    const raw = await fs.promises.readFile(filePath, "utf-8");
    entry = JSON.parse(raw);
  } catch {
    return; // File missing or corrupted — skip update
  }
  entry.retryCount += 1;
  entry.lastAttemptAt = Date.now();
  entry.lastError = error;

  // auto-move to failed/ on max retries or permanent error (#23777)
  if (entry.retryCount >= MAX_RETRIES || isPermanentDeliveryError(error)) {
    // Persist updated entry first (retryCount + lastError for audit trail)
    const tmp = `${filePath}.${process.pid}.tmp`;
    await fs.promises.writeFile(tmp, JSON.stringify(entry, null, 2), {
      encoding: "utf-8",
      mode: 0o600,
    });
    await fs.promises.rename(tmp, filePath);
    // Move to failed/ subdirectory
    await moveToFailed(id, stateDir);
    return;
  }

  const tmp = `${filePath}.${process.pid}.tmp`;
  await fs.promises.writeFile(tmp, JSON.stringify(entry, null, 2), {
    encoding: "utf-8",
    mode: 0o600,
  });
  await fs.promises.rename(tmp, filePath);
}"""

# Try virgin pattern first, then post-#23672
if old_virgin in code:
    code = code.replace(old_virgin, new_virgin, 1)
    print("    OK: #23777 failDelivery patched (virgin source)")
elif old_post23672 in code:
    code = code.replace(old_post23672, new_post23672, 1)
    print("    OK: #23777 failDelivery patched (post-#23672 try-catch preserved)")
else:
    print("    FAIL: #23777 cannot find failDelivery function body (neither virgin nor post-#23672)", file=sys.stderr)
    sys.exit(1)

with open(filepath, "w") as f:
    f.write(code)

PYEOF

echo "    OK: #23777 fully applied"
