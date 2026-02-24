#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw PR Discovery Pipeline v3
# Finds new valuable open PRs that we haven't scanned before.
# Uses scan-registry.json to avoid duplicate scanning.
#
# Usage: ~/.openclaw/my-patches/discover-patches.sh [--all] [--dry-run] [--force]
#
# Flags:
#   --all        Scan ALL open PRs (ignore scan registry)
#   --dry-run    Show candidates without scoring
#   --force      Re-score even previously scanned PRs
#   --min-score N  Minimum treliq score (default: 78)
# ─────────────────────────────────────────────────────────────────────────────

PATCHES_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$PATCHES_DIR/pr-patches.conf"
REGISTRY="$PATCHES_DIR/scan-registry.json"
TRELIQ_DIR="$HOME/clawd/projects/treliq"
WORK="/tmp/openclaw-discover-$$"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }

# Parse flags
SCAN_ALL=false
DRY_RUN=false
FORCE=false
MIN_SCORE=78

while [[ $# -gt 0 ]]; do
  case $1 in
    --all)       SCAN_ALL=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --force)     FORCE=true; shift ;;
    --min-score) MIN_SCORE="$2"; shift 2 ;;
    *)           echo "Unknown flag: $1"; exit 1 ;;
  esac
done

echo ""
echo -e "${CYAN}OpenClaw PR Discovery Pipeline v3${NC}"
echo "  Min score: $MIN_SCORE"
echo "  Scan all: $SCAN_ALL"
echo "  Force rescore: $FORCE"
echo "  Dry run: $DRY_RUN"
echo ""

mkdir -p "$WORK"

# ── Step 1: Load scan registry ───────────────────────────────────────────────
PREVIOUSLY_SCANNED=0
if [ -f "$REGISTRY" ] && [ "$SCAN_ALL" = false ]; then
  PREVIOUSLY_SCANNED=$(node -e "
    const r = JSON.parse(require('fs').readFileSync('$REGISTRY','utf8'));
    console.log(r.scannedPRs.length);
  ")
  info "Scan registry: $PREVIOUSLY_SCANNED PRs previously scanned"
else
  info "No scan registry or --all flag: scanning everything"
fi

# Load already patched PRs from conf
EXISTING_PRS=()
if [ -f "$CONF" ]; then
  while IFS='|' read -r pr_num _; do
    [[ "$pr_num" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$pr_num" ]] && continue
    EXISTING_PRS+=("$(echo "$pr_num" | tr -d ' ')")
  done < "$CONF"
fi
info "Already patched: ${#EXISTING_PRS[@]} PRs"

# ── Step 2: Fetch all open PRs from GitHub ───────────────────────────────────
info "Fetching open PRs from openclaw/openclaw..."

gh api graphql --paginate -f query='
query($cursor: String) {
  repository(owner: "openclaw", name: "openclaw") {
    pullRequests(states: OPEN, first: 100, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
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
}' --jq '.data.repository.pullRequests.nodes[]' > "$WORK/all-prs.jsonl" 2>/dev/null

TOTAL_OPEN=$(wc -l < "$WORK/all-prs.jsonl" | tr -d ' ')
ok "Found $TOTAL_OPEN open PRs"

# ── Step 3: Filter — only NEW PRs (not in registry) ─────────────────────────
info "Filtering for new PRs..."

node -e "
const fs = require('fs');
const lines = fs.readFileSync('$WORK/all-prs.jsonl', 'utf8').trim().split('\n');

// Load previously scanned
let scannedSet = new Set();
let scoredMap = new Map();
try {
  if (!$SCAN_ALL) {
    const reg = JSON.parse(fs.readFileSync('$REGISTRY', 'utf8'));
    scannedSet = new Set(reg.scannedPRs);
    for (const [num, data] of Object.entries(reg.scoredPRs)) {
      scoredMap.set(parseInt(num), data);
    }
  }
} catch {}

const existing = new Set([${EXISTING_PRS[*]+"${EXISTING_PRS[@]/#/}"}]);

const stats = { total: 0, draft: 0, alreadyPatched: 0, alreadyScanned: 0, reverted: 0, tooLarge: 0, candidates: 0 };
const candidates = [];
const allNums = [];

for (const line of lines) {
  try {
    const pr = JSON.parse(line);
    stats.total++;
    allNums.push(pr.number);

    // Skip already patched
    if (existing.has(pr.number)) { stats.alreadyPatched++; continue; }

    // Skip drafts
    if (pr.isDraft) { stats.draft++; continue; }

    // Skip already scanned (unless --force)
    if (!$FORCE && scannedSet.has(pr.number)) { stats.alreadyScanned++; continue; }

    // Net-zero check
    const adds = pr.additions || 0;
    const dels = pr.deletions || 0;
    const total = adds + dels;
    const net = Math.abs(adds - dels);
    if (total >= 10 && total > 0 && (net / total) < 0.05) { stats.reverted++; continue; }

    // Skip truly massive (>2000 lines)
    if (total > 2000) { stats.tooLarge++; continue; }

    // CI + review info
    const ciState = pr.commits?.nodes?.[0]?.commit?.statusCheckRollup?.state || 'UNKNOWN';
    const reviews = (pr.reviews?.nodes || []).map(r => r.state);
    const approved = reviews.includes('APPROVED');
    const changesReq = reviews.includes('CHANGES_REQUESTED');
    const ageMs = Date.now() - new Date(pr.createdAt).getTime();
    const ageDays = Math.round(ageMs / (1000 * 60 * 60 * 24));

    // Skip abandoned (changes_requested + very old)
    if (changesReq && ageDays > 180) continue;

    candidates.push({
      number: pr.number,
      title: pr.title,
      author: pr.author?.login || 'unknown',
      additions: adds,
      deletions: dels,
      changedFiles: pr.changedFiles || 0,
      ci: ciState,
      approved,
      changesReq,
      mergeable: pr.mergeable,
      ageDays,
      labels: (pr.labels?.nodes || []).map(l => l.name),
      createdAt: pr.createdAt,
      updatedAt: pr.updatedAt,
    });
  } catch {}
}

stats.candidates = candidates.length;

// Sort: approved first, then fresh first
candidates.sort((a, b) => {
  if (a.approved !== b.approved) return b.approved ? 1 : -1;
  return a.ageDays - b.ageDays;
});

fs.writeFileSync('$WORK/candidates.json', JSON.stringify(candidates, null, 2));
fs.writeFileSync('$WORK/all-nums.json', JSON.stringify(allNums));

console.log(JSON.stringify(stats));
" 2>/dev/null > "$WORK/stats.json"

STATS=$(cat "$WORK/stats.json")
echo "$STATS" | node -e "
const s = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
console.log('  Total open:         ' + s.total);
console.log('  Draft:              ' + s.draft);
console.log('  Already patched:    ' + s.alreadyPatched);
console.log('  Already scanned:    ' + s.alreadyScanned);
console.log('  Reverted/no-op:     ' + s.reverted);
console.log('  Too large (>2000):  ' + s.tooLarge);
console.log('  NEW CANDIDATES:     ' + s.candidates);
"

CANDIDATE_COUNT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$WORK/candidates.json','utf8')).length)")

if [ "$CANDIDATE_COUNT" -eq 0 ]; then
  ok "No new candidates found. Everything is up to date!"
  rm -rf "$WORK"
  exit 0
fi

ok "Found $CANDIDATE_COUNT new PR candidates"

# ── Step 4: Lightweight pre-scoring ──────────────────────────────────────────
info "Lightweight pre-scoring..."

node -e "
const fs = require('fs');
const candidates = JSON.parse(fs.readFileSync('$WORK/candidates.json', 'utf8'));

function lightScore(pr) {
  let score = 50;
  const reasons = [];

  if (pr.approved) { score += 20; reasons.push('approved'); }
  if (pr.ci === 'SUCCESS') { score += 8; reasons.push('CI ok'); }
  else if (pr.approved) { score += 4; reasons.push('CI fail but approved'); }

  const total = pr.additions + pr.deletions;
  if (total >= 5 && total <= 300) { score += 12; reasons.push('good size'); }
  else if (total > 300 && total <= 800) { score += 5; reasons.push('medium'); }
  else if (total > 800) { score -= 3; reasons.push('large'); }
  else if (total < 5) { score -= 8; reasons.push('tiny'); }

  if (pr.ageDays < 14) { score += 12; reasons.push('fresh'); }
  else if (pr.ageDays < 60) { score += 8; reasons.push('recent'); }
  else if (pr.ageDays < 180) { score += 3; reasons.push('aging'); }
  else { score -= 3; reasons.push('old'); }

  if (/^(feat|fix|refactor|perf|chore|docs|test)(\(.+\))?:/.test(pr.title)) {
    score += 4; reasons.push('conventional');
  }
  if (/^feat/i.test(pr.title)) { score += 6; reasons.push('feature'); }
  if (/^fix|bug|crash|error|patch|hotfix/i.test(pr.title)) { score += 8; reasons.push('bugfix'); }

  const t = pr.title.toLowerCase();
  if (/memory|compact|token|context|truncat|embed|cache/.test(t)) { score += 5; reasons.push('memory/token'); }
  if (/security|sanitiz|permission|inject|xss|escape/.test(t)) { score += 5; reasons.push('security'); }
  if (/crash|race|deadlock|hang|timeout|retry|backoff/.test(t)) { score += 5; reasons.push('stability'); }
  if (/gateway|config|route|schema/.test(t)) { score += 3; reasons.push('gateway/config'); }
  if (/agent|session|subagent|hook|plugin|skill/.test(t)) { score += 3; reasons.push('agent/plugin'); }
  if (/perf|optimi|faster|efficient|reduce|batch|parallel/.test(t)) { score += 4; reasons.push('performance'); }

  if (pr.mergeable === 'MERGEABLE') { score += 3; reasons.push('mergeable'); }
  else if (pr.mergeable === 'CONFLICTING') { score -= 10; reasons.push('conflict'); }
  if (pr.changesReq) { score -= 8; reasons.push('changes_req'); }

  return { ...pr, lightScore: Math.max(0, Math.min(100, score)), reasons };
}

const scored = candidates.map(lightScore).sort((a, b) => b.lightScore - a.lightScore);

// Select top candidates for treliq (lightScore >= 70)
const treliqCandidates = scored.filter(s => s.lightScore >= 70);

fs.writeFileSync('$WORK/treliq-input.json', JSON.stringify(treliqCandidates, null, 2));

console.log('Pre-scored: ' + scored.length);
console.log('For treliq (LS>=70): ' + treliqCandidates.length);
console.log('Est. cost: ~\$' + (treliqCandidates.length * 0.01).toFixed(2));
" 2>/dev/null

TRELIQ_COUNT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$WORK/treliq-input.json','utf8')).length)")

if [ "$TRELIQ_COUNT" -eq 0 ]; then
  ok "No candidates passed pre-scoring."
  rm -rf "$WORK"
  exit 0
fi

ok "Pre-scored: $TRELIQ_COUNT candidates for treliq"

if [ "$DRY_RUN" = true ]; then
  info "Dry run — showing top 20 pre-scored candidates:"
  node -e "
    const fs = require('fs');
    const c = JSON.parse(fs.readFileSync('$WORK/treliq-input.json', 'utf8'));
    c.slice(0, 20).forEach((pr, i) => {
      const ci = pr.ci === 'SUCCESS' ? '' : ' [CI:' + pr.ci + ']';
      const app = pr.approved ? ' [APPROVED]' : '';
      console.log((i+1).toString().padStart(2) + '. #' + pr.number + ' | LS:' + pr.lightScore + app + ci + ' | +' + pr.additions + '/-' + pr.deletions);
      console.log('    ' + pr.title);
    });
  "
  rm -rf "$WORK"
  exit 0
fi

# ── Step 5: Score with treliq ────────────────────────────────────────────────
info "Scoring $TRELIQ_COUNT candidates with treliq..."
echo -e "${YELLOW}  Estimated cost: ~\$$(echo "$TRELIQ_COUNT * 0.01" | bc) | Time: ~$(( TRELIQ_COUNT / 15 + 1 )) min${NC}"
echo ""
echo -e "${CYAN}Proceed? (y/n)${NC}"
read -r PROCEED
if [ "$PROCEED" != "y" ] && [ "$PROCEED" != "Y" ]; then
  info "Cancelled."
  rm -rf "$WORK"
  exit 0
fi

cd "$TRELIQ_DIR"
set -a && source .env && set +a
TRELIQ_INPUT="$WORK/treliq-input.json" \
TRELIQ_OUTPUT="$WORK/treliq-results.json" \
node --import tsx ./bulk-score-openclaw.ts 2>&1

# ── Step 6: Merge results and update registry ───────────────────────────────
info "Merging results and updating registry..."

node -e "
const fs = require('fs');
const path = require('path');

// Load results
const results = JSON.parse(fs.readFileSync('$WORK/treliq-results.json', 'utf8'));
const allNums = JSON.parse(fs.readFileSync('$WORK/all-nums.json', 'utf8'));

// Update registry
let registry;
try {
  registry = JSON.parse(fs.readFileSync('$REGISTRY', 'utf8'));
} catch {
  registry = { scannedPRs: [], scoredPRs: {}, appliedPRs: [], rejectedPRs: {} };
}

// Add new scanned PRs
const scannedSet = new Set(registry.scannedPRs);
for (const num of allNums) scannedSet.add(num);
registry.scannedPRs = [...scannedSet].sort((a, b) => a - b);

// Add new scores
for (const pr of results.rankedPRs) {
  registry.scoredPRs[pr.number] = { score: pr.totalScore, intent: pr.intent, title: pr.title };
}

registry.lastScanAt = new Date().toISOString();
registry.stats = {
  ...registry.stats,
  totalOpenPRsScanned: registry.scannedPRs.length,
  treliqScored: Object.keys(registry.scoredPRs).length,
};

fs.writeFileSync('$REGISTRY', JSON.stringify(registry, null, 2));

// Show high-value results
const highValue = results.rankedPRs
  .filter(p => p.totalScore >= $MIN_SCORE)
  .sort((a, b) => b.totalScore - a.totalScore);

console.log('');
console.log('=== NEW HIGH-VALUE PRs (score >= $MIN_SCORE) ===');
console.log('');
if (highValue.length === 0) {
  console.log('No new high-value PRs found.');
} else {
  highValue.forEach((pr, i) => {
    const size = '+' + pr.additions + '/-' + pr.deletions;
    console.log((i+1) + '. #' + pr.number + ' | Score: ' + pr.totalScore + ' | ' + pr.intent + ' | ' + size);
    console.log('   ' + pr.title);
  });
  console.log('');
  console.log('Total: ' + highValue.length + ' high-value PRs');
}

// Save high-value for review
fs.writeFileSync('$WORK/high-value.json', JSON.stringify(highValue, null, 2));
" 2>/dev/null

ok "Registry updated: $REGISTRY"

# ── Step 7: Cleanup ─────────────────────────────────────────────────────────
echo ""
info "Done! Review high-value PRs and run rebuild when ready."
info "Temp files at: $WORK"
