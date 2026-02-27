#!/usr/bin/env bash
# PR #28572 — fix(memory): allow FTS-only indexing without embedding provider
# Clean apply excluding tests. DIKKATLI: verify LanceDB extension compatibility
set -euo pipefail
cd "$1"

if ! [ -d "src/memory" ]; then echo "ERROR: src/memory not found"; exit 1; fi

# Check if already applied
if grep -q 'ftsOnly\|allowFtsWithoutEmbedding\|skipEmbedding' "src/memory/indexer.ts" 2>/dev/null; then
  echo "SKIP: #28572 already applied"
  exit 0
fi

DIFF="/tmp/oc-pr-diffs/28572.diff"
if [ ! -s "$DIFF" ]; then
  mkdir -p /tmp/oc-pr-diffs
  echo "  Downloading PR #28572 diff..."
  gh pr diff 28572 --repo openclaw/openclaw > "$DIFF" 2>/dev/null || {
    curl -sL "https://github.com/openclaw/openclaw/pull/28572.diff" > "$DIFF"
  }
fi

if [ ! -s "$DIFF" ]; then
  echo "ERROR: cannot download diff for #28572"
  exit 1
fi

git apply --exclude='*test*' "$DIFF" 2>&1
echo "OK: #28572 applied — FTS-only indexing without embedding provider"
