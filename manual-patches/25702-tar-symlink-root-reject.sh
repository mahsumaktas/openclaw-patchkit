#!/usr/bin/env bash
set -euo pipefail
cd "$1"

# PR #25702 — Reject symlink tar extraction roots
# Adds assertDestinationDirReady() call to tar extraction path.
# The function already exists (used by zip extraction), but tar path was missing it.

FILE="src/infra/archive.ts"

if [[ ! -f "$FILE" ]]; then
  echo "SKIP #25702: $FILE not found"
  exit 0
fi

# Idempotency: check if the tar path already calls assertDestinationDirReady
if grep -q 'assertDestinationDirReady(params.destDir)' "$FILE" 2>/dev/null; then
  # Check if it appears TWICE (once for zip, once for tar) — if so, already patched
  COUNT=$(grep -c 'assertDestinationDirReady(params.destDir)' "$FILE" || true)
  if [[ "$COUNT" -ge 2 ]]; then
    echo "SKIP #25702: already patched (assertDestinationDirReady called in tar path)"
    exit 0
  fi
fi

python3 - "$FILE" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# The tar extraction block starts with:
#   if (kind === "tar") {
#     const limits = resolveExtractLimits(params.limits);
#     const stat = await fs.stat(params.archivePath);
# We need to add assertDestinationDirReady(params.destDir) before the limits line.

# Pattern: find the tar block opening
old = '''  if (kind === "tar") {
    const limits = resolveExtractLimits(params.limits);
    const stat = await fs.stat(params.archivePath);'''

new = '''  if (kind === "tar") {
    await assertDestinationDirReady(params.destDir);
    const limits = resolveExtractLimits(params.limits);
    const stat = await fs.stat(params.archivePath);'''

if old not in content:
    # Try alternate: maybe there's already something different in this block
    print(f"FAIL #25702: could not find tar extraction block in {filepath}")
    sys.exit(1)

content = content.replace(old, new, 1)

with open(filepath, 'w') as f:
    f.write(content)

print("OK #25702: added assertDestinationDirReady() to tar extraction path")
PYEOF
