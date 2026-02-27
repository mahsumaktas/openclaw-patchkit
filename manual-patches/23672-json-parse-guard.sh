#!/usr/bin/env bash
# PR #23672 — fix(resilience): guard JSON.parse of external process output with try-catch
# Two fixes:
# 1. bonjour-discovery.ts: parseTailscaleStatusIPv4s wraps JSON.parse in try-catch
# 2. delivery-queue.ts: failDelivery wraps readFile+JSON.parse in try-catch
# NOTE: Must work with #23777 (failDelivery body is different after that patch).
set -euo pipefail

SRC="${1:?Usage: $0 <openclaw-source-dir>}/src"
BONJOUR="$SRC/infra/bonjour-discovery.ts"
DELIVERY="$SRC/infra/outbound/delivery-queue.ts"

# ── Idempotency check ──
APPLIED=0
if [ -f "$BONJOUR" ] && grep -q 'parseTailscaleStatusIPv4s' "$BONJOUR" 2>/dev/null; then
  if grep -A5 'parseTailscaleStatusIPv4s' "$BONJOUR" | grep -q 'try' 2>/dev/null; then
    APPLIED=$((APPLIED + 1))
  fi
fi
if [ -f "$DELIVERY" ] && grep -A10 'async function failDelivery' "$DELIVERY" | grep -q 'try' 2>/dev/null; then
  APPLIED=$((APPLIED + 1))
fi
if [ "$APPLIED" -ge 2 ]; then
  echo "    SKIP: #23672 already applied"
  exit 0
fi

# ── 1. bonjour-discovery.ts: wrap parseTailscaleStatusIPv4s JSON.parse ──
if [ -f "$BONJOUR" ]; then
  python3 - "$BONJOUR" << 'PYEOF'
import sys
import re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Check if already patched
if 'try {' in content.split('parseTailscaleStatusIPv4s')[1].split('return out')[0] if 'parseTailscaleStatusIPv4s' in content else '':
    print("    SKIP: #23672 bonjour-discovery.ts already patched")
    sys.exit(0)

# Match the pattern: const parsed = ... JSON.parse(stdout) ...
old = 'function parseTailscaleStatusIPv4s(stdout: string): string[] {\n  const parsed = stdout ? (JSON.parse(stdout) as Record<string, unknown>) : {};'

if old in content:
    new = '''function parseTailscaleStatusIPv4s(stdout: string): string[] {
  let parsed: Record<string, unknown>;
  try {
    parsed = stdout ? (JSON.parse(stdout) as Record<string, unknown>) : {};
  } catch {
    return [];
  }'''
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #23672 bonjour-discovery.ts patched")
else:
    # Try regex for flexible whitespace
    m = re.search(
        r'(function parseTailscaleStatusIPv4s\(stdout: string\): string\[\] \{\n)'
        r'(\s*const parsed = stdout \? \(JSON\.parse\(stdout\) as Record<string, unknown>\) : \{\};)',
        content
    )
    if m:
        new = m.group(1) + '''  let parsed: Record<string, unknown>;
  try {
    parsed = stdout ? (JSON.parse(stdout) as Record<string, unknown>) : {};
  } catch {
    return [];
  }'''
        content = content.replace(m.group(0), new, 1)
        with open(path, 'w') as f:
            f.write(content)
        print("    OK: #23672 bonjour-discovery.ts patched (regex)")
    else:
        print("    WARN: #23672 parseTailscaleStatusIPv4s pattern not found — skipping")
PYEOF
else
  echo "    SKIP: bonjour-discovery.ts not found"
fi

# ── 2. delivery-queue.ts: wrap failDelivery readFile+JSON.parse ──
if [ -f "$DELIVERY" ]; then
  python3 - "$DELIVERY" << 'PYEOF'
import sys
import re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Check if already patched
m = re.search(r'async function failDelivery.*?\{(.*?)\n\}', content, re.DOTALL)
if m and 'try {' in m.group(1)[:200]:
    print("    SKIP: #23672 delivery-queue.ts already patched")
    sys.exit(0)

# Try the #23777-patched version first (has auto-move logic)
has_23777 = 'isPermanentDeliveryError' in content or 'auto-move to failed/' in content

# Pattern: const raw = await fs.promises.readFile(filePath, "utf-8");
#          const entry: QueuedDelivery = JSON.parse(raw);
old_pattern = re.search(
    r'(  const raw = await fs\.promises\.readFile\(filePath, "utf-8"\);\n'
    r'  const entry: QueuedDelivery = JSON\.parse\(raw\);)',
    content
)

if old_pattern:
    old = old_pattern.group(0)
    new = '''  let entry: QueuedDelivery;
  try {
    const raw = await fs.promises.readFile(filePath, "utf-8");
    entry = JSON.parse(raw);
  } catch {
    return; // File missing or corrupted — skip update
  }'''
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print(f"    OK: #23672 delivery-queue.ts patched (23777={has_23777})")
else:
    print("    WARN: #23672 failDelivery readFile+JSON.parse pattern not found — skipping")
PYEOF
else
  echo "    SKIP: delivery-queue.ts not found"
fi

echo "    DONE: 23672-json-parse-guard applied"
