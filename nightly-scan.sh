#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw Nightly Scan
# Runs at 5 AM daily via cron. Scans last 3 days of PRs, scores with Sonnet,
# checks merged upstream, updates patchkit repo.
#
# Cron: 0 5 * * * ~/.openclaw/my-patches/nightly-scan.sh >> ~/.openclaw/my-patches/nightly.log 2>&1
# ─────────────────────────────────────────────────────────────────────────────

PATCHES_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$PATCHES_DIR/pr-patches.conf"
REGISTRY="$PATCHES_DIR/scan-registry.json"
TRELIQ_DIR="$HOME/clawd/projects/treliq"
PATCHKIT_DIR="$HOME/openclaw-patchkit"
WORK="/tmp/openclaw-nightly-$$"
LOG="$PATCHES_DIR/nightly.log"
SCAN_DAYS=3
MODEL="claude-sonnet-4-6"

# Load PATH for node/gh
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

mkdir -p "$WORK"

echo ""
echo "=== OPENCLAW NIGHTLY SCAN: $(date '+%Y-%m-%d %H:%M') ==="
echo ""

# ── Step 1: Fetch last N days of updated PRs ──────────────────────────────────
SINCE=$(date -v-${SCAN_DAYS}d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || date -d "${SCAN_DAYS} days ago" '+%Y-%m-%dT00:00:00Z')
echo "[1/6] Fetching PRs updated since $SINCE..."

gh api graphql --paginate -f query="
query(\$cursor: String) {
  search(query: \"repo:openclaw/openclaw is:pr is:open updated:>=$SINCE\", type: ISSUE, first: 100, after: \$cursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number
        title
        additions
        deletions
        changedFiles
        isDraft
        mergeable
        createdAt
        updatedAt
        author { login }
        labels(first: 10) { nodes { name } }
        commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup { state }
            }
          }
        }
        reviews(last: 5) {
          nodes { state }
        }
      }
    }
  }
}" --jq '.data.search.nodes[]' > "$WORK/recent-prs.jsonl" 2>/dev/null

TOTAL_RECENT=$(wc -l < "$WORK/recent-prs.jsonl" | tr -d ' ')
echo "  Found $TOTAL_RECENT recently updated PRs"

# ── Step 2: Filter — exclude already fully scanned ────────────────────────────
echo "[2/6] Filtering against scan registry..."

node -e "
const fs = require('fs');
const lines = fs.readFileSync('$WORK/recent-prs.jsonl', 'utf8').trim().split('\n').filter(l => l);

// Load registry
let scannedSet = new Set();
try {
  const reg = JSON.parse(fs.readFileSync('$REGISTRY', 'utf8'));
  scannedSet = new Set(reg.scannedPRs);
} catch {}

// Load patched PRs
const confLines = fs.readFileSync('$CONF', 'utf8').split('\n');
const patched = new Set();
for (const line of confLines) {
  const m = line.match(/^\s*(\d+)\s*\|/);
  if (m) patched.add(parseInt(m[1]));
}

const candidates = [];
for (const line of lines) {
  try {
    const pr = JSON.parse(line);
    if (pr.isDraft) continue;
    if (patched.has(pr.number)) continue;
    // Skip if already scanned with Sonnet (check method in registry)
    if (scannedSet.has(pr.number)) {
      // But re-scan if it was updated after our last scan
      // For now, skip — we trust our full scan
      continue;
    }

    const adds = pr.additions || 0;
    const dels = pr.deletions || 0;
    const total = adds + dels;
    const net = Math.abs(adds - dels);
    if (total >= 10 && total > 0 && (net / total) < 0.05) continue;
    if (total > 3000) continue;

    const ciState = pr.commits?.nodes?.[0]?.commit?.statusCheckRollup?.state || 'UNKNOWN';
    const reviews = (pr.reviews?.nodes || []).map(r => r.state);
    const ageMs = Date.now() - new Date(pr.createdAt).getTime();

    candidates.push({
      number: pr.number,
      title: pr.title,
      author: pr.author?.login || 'unknown',
      additions: adds,
      deletions: dels,
      changedFiles: pr.changedFiles || 0,
      ci: ciState,
      approved: reviews.includes('APPROVED'),
      changesReq: reviews.includes('CHANGES_REQUESTED'),
      mergeable: pr.mergeable,
      categories: [],
      ageDays: Math.round(ageMs / (1000 * 60 * 60 * 24)),
      labels: (pr.labels?.nodes || []).map(l => l.name),
      createdAt: pr.createdAt,
      updatedAt: pr.updatedAt,
    });
  } catch {}
}

fs.writeFileSync('$WORK/new-candidates.json', JSON.stringify(candidates, null, 2));
console.log(candidates.length);
" 2>/dev/null > "$WORK/new-count.txt"

NEW_COUNT=$(cat "$WORK/new-count.txt" | tr -d ' ')
echo "  New candidates to score: $NEW_COUNT"

if [ "$NEW_COUNT" -eq 0 ]; then
  echo "  No new PRs to score. Checking upstream merges..."
  # Skip to step 4
else
  # ── Step 3: Score with treliq + Sonnet ──────────────────────────────────────
  echo "[3/6] Scoring $NEW_COUNT new PRs with Sonnet 4.6..."

  cd "$TRELIQ_DIR"
  set -a && source .env && set +a

  TRELIQ_MODEL="$MODEL" \
  TRELIQ_INPUT="$WORK/new-candidates.json" \
  TRELIQ_OUTPUT="$WORK/treliq-results.json" \
  node --import tsx ./bulk-score-openclaw.ts 2>&1 | tail -5

  # Update registry with new scores
  node -e "
  const fs = require('fs');
  const results = JSON.parse(fs.readFileSync('$WORK/treliq-results.json', 'utf8'));
  const registry = JSON.parse(fs.readFileSync('$REGISTRY', 'utf8'));

  for (const pr of results.rankedPRs) {
    registry.scoredPRs[pr.number] = {
      score: pr.totalScore,
      intent: pr.intent,
      title: pr.title,
      method: 'sonnet-4.6',
      scoredAt: new Date().toISOString(),
    };
    if (!registry.scannedPRs.includes(pr.number)) {
      registry.scannedPRs.push(pr.number);
    }
  }

  registry.scannedPRs.sort((a, b) => a - b);
  registry.lastScanAt = new Date().toISOString();
  registry.stats.totalOpenPRsScanned = registry.scannedPRs.length;
  registry.stats.treliqScored = Object.values(registry.scoredPRs).filter(v => v.score !== null).length;

  fs.writeFileSync('$REGISTRY', JSON.stringify(registry, null, 2));

  // Report high-value findings
  const highValue = results.rankedPRs.filter(p => p.totalScore >= 80).sort((a, b) => b.totalScore - a.totalScore);
  if (highValue.length > 0) {
    console.log('');
    console.log('NEW HIGH-VALUE PRs (score >= 80):');
    for (const pr of highValue) {
      console.log('  #' + pr.number + ' (' + pr.totalScore + ') ' + pr.title);
    }
  }
  console.log('');
  console.log('Registry updated: ' + results.rankedPRs.length + ' new scores');
  " 2>/dev/null
fi

# ── Step 4: Check upstream merges ─────────────────────────────────────────────
echo "[4/6] Checking upstream merges..."

MERGED_PRS=()
CLOSED_PRS=()

while IFS='|' read -r pr_num rest; do
  [[ "$pr_num" =~ ^[[:space:]]*# ]] && continue
  [[ -z "$pr_num" ]] && continue
  pr_num=$(echo "$pr_num" | tr -d ' ')

  STATE=$(gh pr view "$pr_num" --repo openclaw/openclaw --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")

  if [ "$STATE" = "MERGED" ]; then
    MERGED_PRS+=("$pr_num")
    echo "  MERGED: #$pr_num"
  elif [ "$STATE" = "CLOSED" ]; then
    CLOSED_PRS+=("$pr_num")
    echo "  CLOSED: #$pr_num"
  fi
done < "$CONF"

if [ ${#MERGED_PRS[@]} -gt 0 ]; then
  echo "  ${#MERGED_PRS[@]} PR(s) merged upstream — removing from patches"
  for pr in "${MERGED_PRS[@]}"; do
    # Comment out the line in conf
    sed -i '' "s/^${pr} /# ${pr} | MERGED UPSTREAM — /" "$CONF"
  done
fi

# ── Step 5: Update patchkit repo ──────────────────────────────────────────────
echo "[5/6] Updating patchkit repo..."

if [ -d "$PATCHKIT_DIR/.git" ]; then
  cd "$PATCHKIT_DIR"

  # Copy latest files
  cp "$CONF" "$PATCHKIT_DIR/pr-patches.conf"
  cp "$REGISTRY" "$PATCHKIT_DIR/scan-registry.json"
  cp "$PATCHES_DIR/rebuild-with-patches.sh" "$PATCHKIT_DIR/"
  cp "$PATCHES_DIR/discover-patches.sh" "$PATCHKIT_DIR/"
  cp -r "$PATCHES_DIR/manual-patches" "$PATCHKIT_DIR/" 2>/dev/null || true

  # Update README stats
  PATCH_COUNT=$(grep -c '^[0-9]' "$CONF" 2>/dev/null || echo "0")
  SCORED_COUNT=$(node -e "const r=JSON.parse(require('fs').readFileSync('$REGISTRY','utf8')); console.log(Object.values(r.scoredPRs).filter(v=>v.score!==null).length)" 2>/dev/null || echo "0")
  SCANNED_COUNT=$(node -e "const r=JSON.parse(require('fs').readFileSync('$REGISTRY','utf8')); console.log(r.scannedPRs.length)" 2>/dev/null || echo "0")

  # Generate patch table for README
  node -e "
  const fs = require('fs');
  const conf = fs.readFileSync('$CONF', 'utf8');
  const lines = conf.split('\n').filter(l => /^\d/.test(l.trim()));

  let readme = fs.readFileSync('$PATCHKIT_DIR/README.md', 'utf8');

  // Update stats in README
  readme = readme.replace(/\*\*\d+ patches\*\*/, '**' + lines.length + ' patches**');
  readme = readme.replace(/\*\*\d+ PRs scored\*\*/, '**${SCORED_COUNT} PRs scored**');
  readme = readme.replace(/\*\*\d+ PRs scanned\*\*/, '**${SCANNED_COUNT} PRs scanned**');
  readme = readme.replace(/Last updated: .+/, 'Last updated: ' + new Date().toISOString().split('T')[0]);

  fs.writeFileSync('$PATCHKIT_DIR/README.md', readme);
  console.log('README updated');
  " 2>/dev/null

  # Commit and push
  git add -A
  CHANGES=$(git diff --cached --stat | tail -1)
  if [ -n "$CHANGES" ]; then
    DATE=$(date '+%Y-%m-%d')
    NEW_MSG=""
    if [ "$NEW_COUNT" -gt 0 ]; then
      NEW_MSG=", $NEW_COUNT new PRs scored"
    fi
    MERGE_MSG=""
    if [ ${#MERGED_PRS[@]} -gt 0 ]; then
      MERGE_MSG=", ${#MERGED_PRS[@]} merged upstream"
    fi

    git commit -m "nightly: ${DATE} scan${NEW_MSG}${MERGE_MSG}

${PATCH_COUNT} active patches, ${SCORED_COUNT} PRs scored total
$CHANGES" --no-verify 2>/dev/null

    git push origin main 2>/dev/null && echo "  Pushed to GitHub" || echo "  Push failed"
  else
    echo "  No changes to commit"
  fi
else
  echo "  Patchkit repo not found at $PATCHKIT_DIR — skipping"
fi

# ── Step 6: Summary ──────────────────────────────────────────────────────────
echo ""
echo "[6/6] === NIGHTLY SCAN COMPLETE ==="
echo "  Date: $(date '+%Y-%m-%d %H:%M')"
echo "  Recent PRs checked: $TOTAL_RECENT"
echo "  New PRs scored: ${NEW_COUNT:-0}"
echo "  Merged upstream: ${#MERGED_PRS[@]}"
echo "  Closed upstream: ${#CLOSED_PRS[@]}"
echo ""

rm -rf "$WORK"
