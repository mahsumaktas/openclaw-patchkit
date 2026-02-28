#!/usr/bin/env bash
set -euo pipefail

# pre-upgrade-check.sh — Pre-upgrade conflict analysis for OpenClaw patchkit
# Usage: ./pre-upgrade-check.sh [target_version]
#   Example: ./pre-upgrade-check.sh v2026.2.27
#   No args: checks latest release

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/pr-patches.conf"
REPO="openclaw/openclaw"
WEBHOOK_URL=$(cat ~/.openclaw/webhook-url.txt 2>/dev/null || echo "")
CURRENT_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")

# Target version
if [ -n "${1:-}" ]; then
  TARGET_VERSION="$1"
else
  TARGET_VERSION=$(gh api "repos/$REPO/releases/latest" --jq '.tag_name' 2>/dev/null || echo "")
  if [ -z "$TARGET_VERSION" ]; then
    echo "ERROR: Could not determine latest release. Provide version as argument."
    exit 1
  fi
fi

# Same version check
if [ "$CURRENT_VERSION" = "$TARGET_VERSION" ] || [ "v$CURRENT_VERSION" = "$TARGET_VERSION" ]; then
  echo "Already on $TARGET_VERSION — nothing to check."
  exit 0
fi

echo "============================================"
echo "Pre-Upgrade Check: v$CURRENT_VERSION -> $TARGET_VERSION"
echo "============================================"
echo ""

# Counters
CLEAN=0
CONFLICT=0
MERGED=0
FIX_REVIEW=0
TOTAL=0

# Get changed files between versions (GitHub Compare API, max 300 files)
echo "Fetching changed files..."
CHANGED_FILES=$(gh api "repos/$REPO/compare/v${CURRENT_VERSION}...${TARGET_VERSION}" \
  --jq '.files[].filename' 2>/dev/null || echo "")

CHANGED_FILE_COUNT=0
if [ -n "$CHANGED_FILES" ]; then
  CHANGED_FILE_COUNT=$(echo "$CHANGED_FILES" | wc -l | tr -d ' ')
fi

if [ "$CHANGED_FILE_COUNT" -eq 0 ]; then
  echo "WARN: GitHub Compare API returned 0 files (may exceed 300 file limit)"
  echo "Falling back to git clone for full diff..."

  TMPDIR=$(mktemp -d)
  trap "rm -rf $TMPDIR" EXIT

  git clone --depth 1 --branch "$TARGET_VERSION" "https://github.com/$REPO.git" "$TMPDIR/new" 2>/dev/null || {
    echo "ERROR: Could not clone $TARGET_VERSION"
    exit 1
  }
  git clone --depth 1 --branch "v${CURRENT_VERSION}" "https://github.com/$REPO.git" "$TMPDIR/old" 2>/dev/null || {
    echo "ERROR: Could not clone v${CURRENT_VERSION}"
    exit 1
  }

  CHANGED_FILES=$(diff -rq "$TMPDIR/old/src" "$TMPDIR/new/src" 2>/dev/null | \
    grep "differ\|Only" | sed 's|.*old/||;s| and.*||;s|.*Only in ||;s|: |/|' || echo "")
  CHANGED_FILE_COUNT=$(echo "$CHANGED_FILES" | grep -c . || echo 0)

  trap - EXIT
  rm -rf "$TMPDIR"
fi

echo "Found $CHANGED_FILE_COUNT changed files in upstream"
echo ""

# Analyze each active patch
echo "--- Patch Analysis ---"

while IFS= read -r line; do
  # Skip comments, empty, RETIRED lines
  [[ "$line" =~ ^#.*$ ]] && continue
  [[ -z "$line" ]] && continue

  pr_num=$(echo "$line" | awk '{print $1}')
  desc=$(echo "$line" | sed "s/^$pr_num[[:space:]]*//" | sed 's/\[risk:.*//' | xargs)

  # FIX scripts — flag for manual review
  if [[ "$pr_num" =~ ^FIX- ]]; then
    echo "  -> $pr_num: MANUAL REVIEW NEEDED ($desc)"
    FIX_REVIEW=$((FIX_REVIEW + 1))
    TOTAL=$((TOTAL + 1))
    continue
  fi

  # Non-numeric — skip
  [[ ! "$pr_num" =~ ^[0-9]+$ ]] && continue
  TOTAL=$((TOTAL + 1))

  # Check merge status
  merged=$(gh api "repos/$REPO/pulls/$pr_num" --jq '.merged' 2>/dev/null)
  if [ "$merged" = "true" ]; then
    echo "  x #$pr_num: MERGED UPSTREAM — retire candidate ($desc)"
    MERGED=$((MERGED + 1))
    sleep 0.3
    continue
  fi

  # Get files changed by this PR
  PATCH_FILES=$(gh api "repos/$REPO/pulls/$pr_num/files" --jq '.[].filename' 2>/dev/null || echo "")

  if [ -z "$PATCH_FILES" ]; then
    echo "  ? #$pr_num: COULD NOT FETCH FILES ($desc)"
    CLEAN=$((CLEAN + 1))
    sleep 0.3
    continue
  fi

  # Check for file overlap with upstream changes
  OVERLAP=false
  OVERLAP_FILE=""
  for pf in $PATCH_FILES; do
    if echo "$CHANGED_FILES" | grep -qF "$pf"; then
      OVERLAP=true
      OVERLAP_FILE="$pf"
      break
    fi
  done

  if [ "$OVERLAP" = true ]; then
    echo "  ! #$pr_num: FILE OVERLAP ($OVERLAP_FILE) ($desc)"
    CONFLICT=$((CONFLICT + 1))
  else
    CLEAN=$((CLEAN + 1))
  fi

  # Rate limit
  sleep 0.3
done < "$CONF"

# Report
echo ""
echo "============================================"
echo "Pre-upgrade Report: v$CURRENT_VERSION -> $TARGET_VERSION"
echo "============================================"
echo "  Total patches analyzed: $TOTAL"
echo "  OK  $CLEAN patches: no conflict expected"
echo "  !!  $CONFLICT patches: file overlap detected"
echo "  xx  $MERGED patches: merged upstream (retire candidates)"
echo "  ->  $FIX_REVIEW FIX scripts: manual review needed"
echo "============================================"

# Discord notification
if [ -n "$WEBHOOK_URL" ]; then
  REPORT="**Pre-upgrade Report:** \`v$CURRENT_VERSION\` -> \`$TARGET_VERSION\`\n"
  REPORT+="OK $CLEAN clean | !! $CONFLICT conflict | xx $MERGED merged | -> $FIX_REVIEW FIX review"

  curl -s -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{\"content\": \"$REPORT\"}" > /dev/null 2>&1
  echo ""
  echo "Discord notification sent."
fi

# Exit code: conflict > 0 returns 1
if [ "$CONFLICT" -gt 0 ]; then
  exit 1
fi
exit 0
