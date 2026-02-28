#!/usr/bin/env bash
set -euo pipefail

# cognitive-memory-patch.sh — Cognitive Memory v4 extension verification and repair
# Phase 3 of patch-openclaw.sh pipeline
# Verifies the externalized extension at ~/.openclaw/extensions/memory-lancedb/

EXT_DIR="$HOME/.openclaw/extensions/memory-lancedb"
BUNDLED_DIR="$(npm root -g 2>/dev/null)/openclaw/extensions/memory-lancedb"

echo "=== Phase 3: Cognitive Memory Extension Check ==="

# 1. Extension directory exists?
if [ ! -d "$EXT_DIR" ]; then
  echo "WARN: Global extension dir missing: $EXT_DIR"

  if [ -d "$BUNDLED_DIR" ]; then
    echo "Copying from bundled extensions..."
    cp -R "$BUNDLED_DIR" "$EXT_DIR"
    echo "OK: Copied bundled memory-lancedb to global dir"
  else
    echo "ERROR: No memory-lancedb source found (not in global or bundled)"
    echo "Manual intervention required."
    exit 1
  fi
fi

# 2. openclaw.plugin.json exists?
if [ ! -f "$EXT_DIR/openclaw.plugin.json" ]; then
  echo "ERROR: openclaw.plugin.json missing in $EXT_DIR"
  exit 1
fi
echo "OK: openclaw.plugin.json present"

# 3. index.ts exists and is v4?
if [ ! -f "$EXT_DIR/index.ts" ]; then
  echo "ERROR: index.ts missing"
  exit 1
fi

LINE_COUNT=$(wc -l < "$EXT_DIR/index.ts" | tr -d ' ')
echo "OK: index.ts present ($LINE_COUNT lines)"

if [ "$LINE_COUNT" -lt 1500 ]; then
  echo "WARN: index.ts has only $LINE_COUNT lines (v4 expected ~1602)"
  echo "This may be an older version."

  if [ -f "$EXT_DIR/index.ts.bak.v32" ]; then
    echo "NOTE: v3.2 backup available at index.ts.bak.v32"
  fi
fi

# 4. v4 feature markers
V4_MARKERS=0
if grep -q "pruneEnabled" "$EXT_DIR/index.ts" 2>/dev/null; then
  V4_MARKERS=$((V4_MARKERS + 1))
fi
if grep -q "entityGraph" "$EXT_DIR/index.ts" 2>/dev/null; then
  V4_MARKERS=$((V4_MARKERS + 1))
fi
if grep -q "moodDetection" "$EXT_DIR/index.ts" 2>/dev/null; then
  V4_MARKERS=$((V4_MARKERS + 1))
fi
if grep -q "accessCount" "$EXT_DIR/index.ts" 2>/dev/null; then
  V4_MARKERS=$((V4_MARKERS + 1))
fi

if [ "$V4_MARKERS" -ge 3 ]; then
  echo "OK: Cognitive Memory v4 confirmed ($V4_MARKERS/4 markers found)"
else
  echo "WARN: Only $V4_MARKERS/4 v4 markers found — may not be full v4"
fi

# 5. config.ts exists?
if [ -f "$EXT_DIR/config.ts" ]; then
  CONFIG_LINES=$(wc -l < "$EXT_DIR/config.ts" | tr -d ' ')
  echo "OK: config.ts present ($CONFIG_LINES lines)"
else
  echo "WARN: config.ts missing"
fi

# 6. LanceDB native bindings check
if [ -d "$EXT_DIR/node_modules" ]; then
  echo "OK: node_modules present (LanceDB bindings)"
else
  echo "WARN: node_modules missing — LanceDB may not work"
  echo "Fix: cd $EXT_DIR && npm install"
fi

# 7. Backup files check
BACKUPS=0
[ -f "$EXT_DIR/index.ts.bak.v32" ] && BACKUPS=$((BACKUPS + 1))
[ -f "$EXT_DIR/config.ts.bak.v32" ] && BACKUPS=$((BACKUPS + 1))
echo "OK: $BACKUPS/2 backup files present"

echo ""
echo "=== Phase 3 Complete ==="
exit 0
