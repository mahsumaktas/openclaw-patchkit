#!/bin/bash
# Cognitive Memory Patch for OpenClaw memory-lancedb extension
# Features: Activation scoring, Confidence gating, Semantic dedup merge, Category-based decay
# Idempotent: safe to re-run after OpenClaw updates
#
# Based on research: Self-RAG (ICLR 2024), MaRS benchmark (Dec 2025), ACT-R cognitive model
# See: ~/clawd/research/reviewed/cognitive-memory-pr-specs.md
#       ~/clawd/research/reviewed/cognitive-memory-scientific-validation.md

set -e

TARGET_DIR="/opt/homebrew/lib/node_modules/openclaw/extensions/memory-lancedb"
BACKUP_DIR="$HOME/.openclaw/my-patches/manual-patches/cognitive-memory-backup"
INDEX_FILE="$TARGET_DIR/index.ts"
CONFIG_FILE="$TARGET_DIR/config.ts"

# Check if already patched
if grep -q "accessCount" "$INDEX_FILE" 2>/dev/null; then
  echo "✅ cognitive-memory-patch: already applied (accessCount found in index.ts)"
  exit 0
fi

# Check target exists
if [ ! -f "$INDEX_FILE" ]; then
  echo "❌ cognitive-memory-patch: $INDEX_FILE not found"
  exit 1
fi

# Backup originals
mkdir -p "$BACKUP_DIR"
cp "$INDEX_FILE" "$BACKUP_DIR/index.ts.original"
cp "$CONFIG_FILE" "$BACKUP_DIR/config.ts.original"

# Apply patched files
cp "$BACKUP_DIR/index.ts.patched" "$INDEX_FILE"
cp "$BACKUP_DIR/config.ts.patched" "$CONFIG_FILE"

echo "✅ cognitive-memory-patch: applied successfully"
echo "   Features: activation scoring, confidence gating, semantic dedup, category decay"
echo "   Originals backed up to: $BACKUP_DIR/"
