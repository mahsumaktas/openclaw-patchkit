#!/usr/bin/env bash
# PR #26533 — fix(security): add brute-force protection to pairing code validation
# Tracks failed attempts per pairing request and auto-expires after 10 wrong guesses.
# Only increments for account-scoped requests matching the caller's accountId.
set -euo pipefail
SRC="${1:-.}/src"

FILE="$SRC/pairing/pairing-store.ts"

# Idempotency check
if grep -q 'PAIRING_MAX_FAILED_ATTEMPTS' "$FILE" 2>/dev/null; then
  echo "    SKIP: #26533 already applied"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1) Add PAIRING_MAX_FAILED_ATTEMPTS constant
old_const = 'const PAIRING_PENDING_MAX = 3;'
new_const = 'const PAIRING_PENDING_MAX = 3;\nconst PAIRING_MAX_FAILED_ATTEMPTS = 10;'

if old_const not in content:
    print("    FAIL: #26533 PAIRING_PENDING_MAX pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_const, new_const, 1)

# 2) Add failedAttempts to PairingRequest type
old_type = '  meta?: Record<string, string>;\n};'
new_type = '  meta?: Record<string, string>;\n  /** Number of failed code validation attempts against this request. */\n  failedAttempts?: number;\n};'

# Find only the first occurrence (PairingRequest type)
idx = content.find(old_type)
if idx < 0:
    print("    FAIL: #26533 PairingRequest type pattern not found", file=sys.stderr)
    sys.exit(1)

content = content[:idx] + new_type + content[idx + len(old_type):]

# 3) Add requestShouldTrackFailedAttempt helper after shouldIncludeLegacyAllowFromEntries
old_helper = 'function normalizeId(value: string | number): string {'
new_helper = '''function requestShouldTrackFailedAttempt(
  entry: PairingRequest,
  normalizedAccountId: string,
): boolean {
  const entryAccountId = String(entry.meta?.accountId ?? "")
    .trim()
    .toLowerCase();
  const resolvedEntryAccountId = entryAccountId || DEFAULT_ACCOUNT_ID;
  const resolvedAccountId = normalizedAccountId || DEFAULT_ACCOUNT_ID;
  return resolvedEntryAccountId === resolvedAccountId;
}

function normalizeId(value: string | number): string {'''

if old_helper not in content:
    print("    FAIL: #26533 normalizeId pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_helper, new_helper, 1)

# 4) Replace the wrong-code branch in approveChannelPairingCode
old_wrong = '''      if (idx < 0) {
        if (removed) {
          await writeJsonFile(filePath, {
            version: 1,
            requests: pruned,
          } satisfies PairingStore);
        }
        return null;
      }'''

new_wrong = '''      if (idx < 0) {
        // Wrong code — increment failed attempts on all matching pending requests.
        // If any request exceeds the threshold, expire it to prevent brute-force.
        let mutated = removed;
        const surviving: PairingRequest[] = [];
        for (const req of pruned) {
          if (!requestShouldTrackFailedAttempt(req, normalizedAccountId)) {
            surviving.push(req);
            continue;
          }
          const attempts = (req.failedAttempts ?? 0) + 1;
          if (attempts >= PAIRING_MAX_FAILED_ATTEMPTS) {
            // Auto-expire: too many wrong guesses
            mutated = true;
            continue;
          }
          surviving.push({ ...req, failedAttempts: attempts });
          mutated = true;
        }
        if (mutated) {
          await writeJsonFile(filePath, {
            version: 1,
            requests: surviving,
          } satisfies PairingStore);
        }
        return null;
      }'''

if old_wrong not in content:
    print("    FAIL: #26533 approveChannelPairingCode wrong-code branch not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_wrong, new_wrong, 1)

with open(path, 'w') as f:
    f.write(content)
PYEOF

echo "    OK: #26533 brute-force pairing code protection applied"
