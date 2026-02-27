#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw Nightly Scan
# Runs at 5 AM daily via cron. Scans last 3 days of PRs, scores with Sonnet,
# checks merged upstream, updates patchkit repo.
#
# Cron: 0 5 * * * ~/.openclaw/my-patches/nightly-scan.sh >> ~/.openclaw/my-patches/nightly.log 2>&1
#
# STABILITY-FIRST POLICY:
#   Auto-add only stability intents (bugfix, security, crash, reliability).
#   Feature/refactor PRs: notify-only, require manual approval.
# ─────────────────────────────────────────────────────────────────────────────

# Stability-first: intents eligible for auto-add (all others = manual)
STABILITY_INTENTS="bugfix|fix|crash|security|hardening|reliability|resilience|recovery|guard|defense|sanitize|prevent"

PATCHES_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$PATCHES_DIR/pr-patches.conf"
REGISTRY="$PATCHES_DIR/scan-registry.json"
TRELIQ_DIR="$HOME/clawd/projects/treliq"
PATCHKIT_DIR="$HOME/openclaw-patchkit"
WORK="/tmp/openclaw-nightly-$$"
LOG="$PATCHES_DIR/nightly.log"
FEATURE_DEFERRED_COUNT=0
SCAN_DAYS=3
MODEL="claude-sonnet-4-6"

# Load PATH for node/gh
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

# Load Discord notifications (non-fatal if missing)
# shellcheck disable=SC1091
source "$PATCHES_DIR/notify.sh" 2>/dev/null || true

mkdir -p "$WORK"

echo ""
echo "=== OPENCLAW NIGHTLY SCAN: $(date '+%Y-%m-%d %H:%M') ==="
echo ""

# ── Step 1: Fetch last N days of updated PRs ──────────────────────────────────
SINCE=$(date -v-${SCAN_DAYS}d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || date -d "${SCAN_DAYS} days ago" '+%Y-%m-%dT00:00:00Z')
echo "[1/7] Fetching PRs updated since $SINCE..."

MAX_PAGES=5
MAX_PRS=500
CURSOR=""
> "$WORK/recent-prs.jsonl"

# Load registry for early-exit check
SCANNED_SET=$(node -e "
try {
  const r = JSON.parse(require('fs').readFileSync('$REGISTRY','utf8'));
  console.log(JSON.stringify(r.scannedPRs || []));
} catch { console.log('[]'); }
" 2>/dev/null)

for PAGE in $(seq 1 $MAX_PAGES); do
  CURSOR_ARG=""
  if [ -n "$CURSOR" ]; then
    CURSOR_ARG="-f cursor=$CURSOR"
  fi

  # Retry API calls up to 3 times with backoff (handles transient network/rate-limit errors)
  API_OK=false
  for ATTEMPT in 1 2 3; do
    API_ERR=""
    RESPONSE=$(gh api graphql -f query="
query(\$cursor: String) {
  search(query: \"repo:openclaw/openclaw is:pr is:open updated:>=$SINCE sort:updated-desc\", type: ISSUE, first: 100, after: \$cursor) {
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
}" $CURSOR_ARG 2>"$WORK/api-err-$PAGE.txt") && API_OK=true && break
    API_ERR=$(cat "$WORK/api-err-$PAGE.txt" 2>/dev/null | head -3)
    BACKOFF=$((ATTEMPT * 15))
    echo "  API error on page $PAGE attempt $ATTEMPT/3: ${API_ERR:-unknown error}"
    echo "  Retrying in ${BACKOFF}s..."
    sleep $BACKOFF
  done

  if [ "$API_OK" != "true" ]; then
    echo "  API failed after 3 attempts on page $PAGE — stopping."
    echo "  Last error: ${API_ERR:-unknown}"
    break
  fi

  # Extract nodes and append
  echo "$RESPONSE" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const nodes=d.data?.search?.nodes||[];
for(const n of nodes) console.log(JSON.stringify(n));
" >> "$WORK/recent-prs.jsonl" 2>/dev/null

  # Check pagination
  HAS_NEXT=$(echo "$RESPONSE" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
console.log(d.data?.search?.pageInfo?.hasNextPage?'true':'false');
" 2>/dev/null)
  CURSOR=$(echo "$RESPONSE" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
console.log(d.data?.search?.pageInfo?.endCursor||'');
" 2>/dev/null)

  CURRENT_COUNT=$(wc -l < "$WORK/recent-prs.jsonl" | tr -d ' ')
  echo "  Page $PAGE: $CURRENT_COUNT PRs fetched so far"

  # Early exit: check if this page has any unscanned PRs
  PAGE_NEW=$(echo "$RESPONSE" | node -e "
const d=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const scanned=new Set($SCANNED_SET);
const nodes=d.data?.search?.nodes||[];
const newCount=nodes.filter(n=>!n.isDraft&&!scanned.has(n.number)).length;
console.log(newCount);
" 2>/dev/null)

  if [ "${PAGE_NEW:-0}" -eq 0 ] && [ "$PAGE" -gt 1 ]; then
    echo "  No new unscanned PRs on page $PAGE — stopping early."
    break
  fi

  if [ "$HAS_NEXT" != "true" ] || [ "$CURRENT_COUNT" -ge "$MAX_PRS" ]; then
    break
  fi

  sleep 1  # Rate limit courtesy
done

TOTAL_RECENT=$(wc -l < "$WORK/recent-prs.jsonl" | tr -d ' ')
echo "  Found $TOTAL_RECENT recently updated PRs (max $MAX_PRS)"

# ── Step 2: Filter — exclude already fully scanned ────────────────────────────
echo "[2/7] Filtering against scan registry..."

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

// Load previously skipped drafts for re-check
let skippedDrafts = new Set();
try {
  const reg = JSON.parse(fs.readFileSync('$REGISTRY', 'utf8'));
  skippedDrafts = new Set(reg.skippedDrafts || []);
} catch {}

const candidates = [];
const currentDrafts = [];

for (const line of lines) {
  try {
    const pr = JSON.parse(line);

    // Track drafts — skip now but re-check next night if they become ready
    if (pr.isDraft) {
      currentDrafts.push(pr.number);
      continue;
    }

    // Was this a previously skipped draft that's now ready? Force scan it.
    const wasDraft = skippedDrafts.has(pr.number);

    if (patched.has(pr.number)) continue;
    // Skip if already scanned — unless it was a draft we're re-checking
    if (scannedSet.has(pr.number) && !wasDraft) continue;

    const adds = pr.additions || 0;
    const dels = pr.deletions || 0;
    const total = adds + dels;
    const net = Math.abs(adds - dels);
    // Skip format-only changes (>95% additions or deletions, no real diff)
    if (total >= 10 && total > 0 && (net / total) < 0.05) continue;

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
      large: total > 3000,
      ci: ciState,
      approved: reviews.includes('APPROVED'),
      changesReq: reviews.includes('CHANGES_REQUESTED'),
      mergeable: pr.mergeable,
      categories: [],
      ageDays: Math.round(ageMs / (1000 * 60 * 60 * 24)),
      labels: (pr.labels?.nodes || []).map(l => l.name),
      createdAt: pr.createdAt,
      updatedAt: pr.updatedAt,
      wasDraft: wasDraft,
    });
  } catch {}
}

// Update skippedDrafts in registry
try {
  const reg = JSON.parse(fs.readFileSync('$REGISTRY', 'utf8'));
  reg.skippedDrafts = currentDrafts;
  fs.writeFileSync('$REGISTRY', JSON.stringify(reg, null, 2));
} catch {}

const draftRecovered = candidates.filter(c => c.wasDraft).length;
const largeCount = candidates.filter(c => c.large).length;
if (draftRecovered > 0) console.error('  Draft recovered (now ready): ' + draftRecovered);
if (largeCount > 0) console.error('  Large PRs (>3000 lines, included): ' + largeCount);

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
  echo "[3/7] Scoring $NEW_COUNT new PRs with Sonnet 4.6..."

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

  # ── Step 3.1: Discord notification with stability-first classification ────
  node -e "
  const fs = require('fs');
  const results = JSON.parse(fs.readFileSync('$WORK/treliq-results.json', 'utf8'));
  const notable = results.rankedPRs.filter(p => p.totalScore >= 67).sort((a, b) => b.totalScore - a.totalScore);
  if (notable.length === 0) process.exit(0);

  const stabilityRe = /^(${STABILITY_INTENTS})$/i;
  const lines = notable.map(p => {
    const tier = p.totalScore >= 80 ? 'CRITICAL' : 'HIGH';
    const intent = (p.intent || 'unknown').toLowerCase();
    const isStability = stabilityRe.test(intent);
    const tag = isStability ? 'STABILITY' : 'FEATURE';
    const autoEligible = isStability ? ' [auto-eligible]' : ' [manual-only]';
    return '[' + tier + '] [' + tag + '] **#' + p.number + '** (' + p.totalScore + ') ' + p.title + autoEligible;
  });

  const stabilityCount = notable.filter(p => stabilityRe.test((p.intent || '').toLowerCase())).length;
  const featureCount = notable.length - stabilityCount;
  const summary = 'Stability: ' + stabilityCount + ' | Feature: ' + featureCount + ' (feature PRs require manual approval)';
  lines.unshift(summary);
  lines.unshift('');

  fs.writeFileSync('$WORK/discord-notable.txt', lines.join('\n'));
  console.log(notable.length);
  " 2>/dev/null > "$WORK/notable-count.txt"

  NOTABLE_COUNT=$(cat "$WORK/notable-count.txt" 2>/dev/null | tr -d ' ')
  if [ -n "$NOTABLE_COUNT" ] && [ "$NOTABLE_COUNT" -gt 0 ] 2>/dev/null; then
    NOTABLE_MSG=$(cat "$WORK/discord-notable.txt" 2>/dev/null)
    notify "Nightly Scan: $NOTABLE_COUNT Notable PRs (Stability-First)" "$NOTABLE_MSG" "blue"
    echo "  Discord: notified $NOTABLE_COUNT notable PRs (score >= 67)"
  fi

  # ── Step 3.5: Auto-add high-confidence STABILITY PRs ────────────────────────
  # STABILITY-FIRST: Only bugfix/security/crash PRs can be auto-added.
  # Feature/refactor PRs are notified but require manual approval.
  echo "[3.5/7] Auto-add: checking STABILITY PRs with score >= 85..."

  AUTO_ADDED=""
  AUTO_ADD_COUNT=0
  FEATURE_DEFERRED_COUNT=0

  OPENCLAW_ROOT_RESOLVED="$(npm root -g)/openclaw"
  OPENCLAW_TAG=$(node -e "console.log('v'+require('$OPENCLAW_ROOT_RESOLVED/package.json').version)" 2>/dev/null)

  node -e "
  const fs = require('fs');
  const results = JSON.parse(fs.readFileSync('$WORK/treliq-results.json', 'utf8'));
  const conf = fs.readFileSync('$CONF', 'utf8');
  const existing = new Set();
  for (const line of conf.split('\n')) {
    const m = line.match(/^\s*#?\s*(\d+)\s*\|/);
    if (m) existing.add(parseInt(m[1]));
  }

  const stabilityRe = /^(${STABILITY_INTENTS})$/i;
  const highScore = results.rankedPRs
    .filter(p => p.totalScore >= 85 && !existing.has(p.number))
    .sort((a, b) => b.totalScore - a.totalScore);

  // Stability-first gate: only stability intents auto-add
  const candidates = [];
  const deferred = [];
  for (const p of highScore) {
    const intent = (p.intent || 'unknown').toLowerCase();
    if (stabilityRe.test(intent)) {
      candidates.push(p);
    } else {
      deferred.push(p);
    }
  }

  fs.writeFileSync('$WORK/auto-add-candidates.json', JSON.stringify(candidates, null, 2));
  fs.writeFileSync('$WORK/auto-add-deferred.json', JSON.stringify(deferred, null, 2));
  // Output: eligible,deferred
  console.log(candidates.length + ',' + deferred.length);
  " 2>/dev/null > "$WORK/auto-add-count.txt"

  AUTO_COUNTS=$(cat "$WORK/auto-add-count.txt" 2>/dev/null | tr -d ' ')
  AUTO_CANDIDATE_COUNT=$(echo "$AUTO_COUNTS" | cut -d',' -f1)
  FEATURE_DEFERRED_COUNT=$(echo "$AUTO_COUNTS" | cut -d',' -f2)
  echo "  Stability candidates for auto-add: ${AUTO_CANDIDATE_COUNT:-0}"
  if [ "${FEATURE_DEFERRED_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    echo "  Feature/refactor PRs deferred (manual-only): $FEATURE_DEFERRED_COUNT"
    # Notify about deferred feature PRs
    DEFERRED_MSG=$(node -e "
    const d=JSON.parse(require('fs').readFileSync('$WORK/auto-add-deferred.json','utf8'));
    console.log(d.map(p=>'#'+p.number+' ('+p.totalScore+') '+p.intent+': '+p.title).join('\n'));
    " 2>/dev/null)
    notify "Stability-First: $FEATURE_DEFERRED_COUNT Feature PR(s) Need Manual Review" "$DEFERRED_MSG\n\nThese scored >= 85 but are feature/refactor — not auto-added per stability-first policy." "yellow"
  fi

  if [ -n "$AUTO_CANDIDATE_COUNT" ] && [ "$AUTO_CANDIDATE_COUNT" -gt 0 ] 2>/dev/null; then
    # Clone source for apply-check (reuse if already cloned)
    CLONE_DIR="/tmp/openclaw-source-$$"
    if [ ! -d "$CLONE_DIR" ]; then
      echo "  Cloning openclaw source ($OPENCLAW_TAG) for apply-check..."
      git clone --depth 200 --branch "$OPENCLAW_TAG" --single-branch \
        https://github.com/openclaw/openclaw.git "$CLONE_DIR" 2>/dev/null || {
          echo "  Clone failed — skipping auto-add."
          AUTO_CANDIDATE_COUNT=0
        }
    fi
  fi

  if [ -n "$AUTO_CANDIDATE_COUNT" ] && [ "$AUTO_CANDIDATE_COUNT" -gt 0 ] 2>/dev/null && [ -d "${CLONE_DIR:-/nonexistent}" ]; then
    # Test each candidate with git apply --check
    node -e "
    const fs = require('fs');
    const { execFileSync } = require('child_process');
    const candidates = JSON.parse(fs.readFileSync('$WORK/auto-add-candidates.json', 'utf8'));
    const cloneDir = '$CLONE_DIR';
    const workDir = '$WORK';
    const passed = [];

    for (const pr of candidates) {
      const diffFile = workDir + '/pr-' + pr.number + '.diff';
      try {
        // Download diff
        execFileSync('gh', ['pr', 'diff', String(pr.number), '--repo', 'openclaw/openclaw'], {
          timeout: 30000,
          stdio: ['pipe', fs.openSync(diffFile, 'w'), 'pipe']
        });
        const diffContent = fs.readFileSync(diffFile, 'utf8');
        if (!diffContent.trim()) continue;

        // Try 4 strategies: clean -> exclude-test -> exclude-changelog+test -> 3way
        const strategies = [
          { name: 'clean', excludes: [] },
          { name: 'exclude-test', excludes: ['**/test/**', '**/__tests__/**', '**/*.test.*', '**/*.spec.*'] },
          { name: 'exclude-changelog+test', excludes: ['**/test/**', '**/__tests__/**', '**/*.test.*', '**/*.spec.*', 'CHANGELOG*', '**/CHANGELOG*'] },
          { name: '3way', excludes: [], threeWay: true },
        ];

        let applied = false;
        for (const strat of strategies) {
          try {
            const args = ['apply', '--check'];
            for (const ex of strat.excludes) args.push('--exclude', ex);
            if (strat.threeWay) args.push('--3way');
            args.push(diffFile);
            execFileSync('git', args, { cwd: cloneDir, timeout: 10000, stdio: 'pipe' });
            passed.push({ number: pr.number, title: pr.title, score: pr.totalScore, strategy: strat.name, intent: pr.intent || '' });
            applied = true;
            break;
          } catch {}
        }

        if (!applied) {
          console.error('  SKIP #' + pr.number + ' — does not apply cleanly');
        }
      } catch (e) {
        console.error('  SKIP #' + pr.number + ' — ' + (e.message || 'unknown error'));
      }
    }

    fs.writeFileSync('$WORK/auto-add-passed.json', JSON.stringify(passed, null, 2));
    console.log(passed.length);
    " 2>/dev/null > "$WORK/auto-add-passed-count.txt"

    PASSED_COUNT=$(cat "$WORK/auto-add-passed-count.txt" 2>/dev/null | tr -d ' ')
    echo "  Passed apply-check: ${PASSED_COUNT:-0}"

    if [ -n "$PASSED_COUNT" ] && [ "$PASSED_COUNT" -gt 0 ] 2>/dev/null; then
      # Add to conf
      DATE_STAMP=$(date '+%Y-%m-%d')
      AUTO_ADDED_LIST=$(node -e "
      const fs = require('fs');
      const passed = JSON.parse(fs.readFileSync('$WORK/auto-add-passed.json', 'utf8'));
      const confPath = '$CONF';
      let conf = fs.readFileSync(confPath, 'utf8');

      const addedNums = [];
      let newLines = '\n# ── Auto-added: $DATE_STAMP (score >= 85, apply-check passed) ──────────────\n';

      for (const pr of passed) {
        const stratNote = pr.strategy !== 'clean' ? ' [' + pr.strategy + ']' : '';
        newLines += pr.number + ' | ' + pr.intent + ': ' + pr.title + stratNote + ' # AUTO-ADDED $DATE_STAMP score=' + pr.score + '\n';
        addedNums.push(pr.number);
      }

      conf = conf.trimEnd() + '\n' + newLines;
      fs.writeFileSync(confPath, conf);
      console.log(addedNums.join(','));
      " 2>/dev/null)

      AUTO_ADDED="$AUTO_ADDED_LIST"
      AUTO_ADD_COUNT=$PASSED_COUNT
      echo "  Auto-added to conf: $AUTO_ADDED"

      # Rebuild with new patches (set +e so rollback runs on failure)
      echo "  Running patch system with new PRs..."
      set +e
      sudo bash "$PATCHES_DIR/patch-openclaw.sh" --skip-restart
      BUILD_EXIT=$?
      set -e

      if [ $BUILD_EXIT -eq 0 ]; then
        echo "  Build successful with auto-added PRs."
        notify "Auto-Add Success" "**$AUTO_ADD_COUNT PR(s)** auto-added and built:\n$AUTO_ADDED" "green"

        # Restart gateway + health monitor
        UID_NUM=$(id -u)
        if launchctl print "gui/$UID_NUM/ai.openclaw.gateway" &>/dev/null; then
          launchctl kill SIGTERM "gui/$UID_NUM/ai.openclaw.gateway"
          sleep 2
          echo "  Gateway restarted."
        fi

        # Health monitor with rollback tracking
        if [ -x "$PATCHES_DIR/health-monitor.sh" ]; then
          nohup bash "$PATCHES_DIR/health-monitor.sh" --auto-added-prs "$AUTO_ADDED" \
            >> "$PATCHES_DIR/../logs/health-monitor.log" 2>&1 &
          echo "  Health monitor started with rollback tracking."
        fi
      else
        echo "  Build FAILED with auto-added PRs — rolling back..."
        # Rollback: comment out auto-added lines
        IFS=',' read -ra ROLLBACK_LIST <<< "$AUTO_ADDED"
        for pr in "${ROLLBACK_LIST[@]}"; do
          sed -i '' "s/^${pr} /# BUILD-FAIL: ${pr} /" "$CONF" 2>/dev/null || true
        done
        # Rebuild without them
        sudo bash "$PATCHES_DIR/patch-openclaw.sh" --skip-restart 2>/dev/null || true
        notify "Auto-Add Build Failed" "Build failed after adding: $AUTO_ADDED\nRolled back. Manual review needed." "red"
        AUTO_ADD_COUNT=0
        AUTO_ADDED=""
      fi
    fi

    # Cleanup clone
    rm -rf "${CLONE_DIR:-/tmp/nonexistent}" 2>/dev/null || true
  fi
fi

# ── Step 4: Check upstream merges ─────────────────────────────────────────────
echo "[4/7] Checking upstream merges..."

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
  MERGED_LIST=""
  for pr in "${MERGED_PRS[@]}"; do
    # Comment out the line in conf
    sed -i '' "s/^${pr} /# ${pr} | MERGED UPSTREAM — /" "$CONF"
    MERGED_LIST="${MERGED_LIST}#${pr} "
  done
  notify "PRs Merged Upstream" "${#MERGED_PRS[@]} PR(s) merged and removed from patches:\n$MERGED_LIST" "green"
fi

# ── Step 5: Update patchkit repo ──────────────────────────────────────────────
echo "[5/7] Updating patchkit repo..."

if [ -d "$PATCHKIT_DIR/.git" ]; then
  cd "$PATCHKIT_DIR"

  # Copy latest files
  cp "$CONF" "$PATCHKIT_DIR/pr-patches.conf"
  cp "$REGISTRY" "$PATCHKIT_DIR/scan-registry.json"
  cp "$PATCHES_DIR/rebuild-with-patches.sh" "$PATCHKIT_DIR/"
  cp "$PATCHES_DIR/discover-patches.sh" "$PATCHKIT_DIR/"
  cp "$PATCHES_DIR/notify.sh" "$PATCHKIT_DIR/"
  cp "$PATCHES_DIR/health-monitor.sh" "$PATCHKIT_DIR/"
  cp "$PATCHES_DIR/post-update-check.sh" "$PATCHKIT_DIR/"
  cp "$PATCHES_DIR/nightly-scan.sh" "$PATCHKIT_DIR/"
  cp "$PATCHES_DIR/install-sudoers.sh" "$PATCHKIT_DIR/"
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

    AUTO_MSG=""
    if [ "${AUTO_ADD_COUNT:-0}" -gt 0 ]; then
      AUTO_MSG=", $AUTO_ADD_COUNT auto-added"
    fi

    git commit -m "nightly: ${DATE} scan${NEW_MSG}${MERGE_MSG}${AUTO_MSG}

${PATCH_COUNT} active patches, ${SCORED_COUNT} PRs scored total
$CHANGES" --no-verify 2>/dev/null

    git push origin main 2>/dev/null && echo "  Pushed to GitHub" || echo "  Push failed"
  else
    echo "  No changes to commit"
  fi
else
  echo "  Patchkit repo not found at $PATCHKIT_DIR — skipping"
fi

# ── Step 7: Summary ──────────────────────────────────────────────────────────
echo ""
echo "[7/7] === NIGHTLY SCAN COMPLETE ==="
echo "  Date: $(date '+%Y-%m-%d %H:%M')"
echo "  Recent PRs checked: $TOTAL_RECENT"
echo "  New PRs scored: ${NEW_COUNT:-0}"
echo "  Auto-added (stability only): ${AUTO_ADD_COUNT:-0}"
echo "  Feature PRs deferred (manual): ${FEATURE_DEFERRED_COUNT:-0}"
echo "  Merged upstream: ${#MERGED_PRS[@]}"
echo "  Closed upstream: ${#CLOSED_PRS[@]}"
echo "  Policy: STABILITY-FIRST (feature/refactor PRs require manual approval)"
echo ""

rm -rf "$WORK"
