#!/usr/bin/env bash
set -euo pipefail
cd "$1"

# PR #16812 — Add preferSessionLookupForAnnounceTarget to channel plugins
# Fixes sessions_send failing by enabling session lookup for announce targets
# in Discord, Signal, Slack, and Telegram channel plugins.
# NOTE: Slack already has this in v2026.3.2, so we only patch Discord, Signal, Telegram.

DISCORD="extensions/discord/src/channel.ts"
SIGNAL="extensions/signal/src/channel.ts"
SLACK="extensions/slack/src/channel.ts"
TELEGRAM="extensions/telegram/src/channel.ts"

patched=0
skipped=0

# --- Discord ---
if [[ -f "$DISCORD" ]]; then
  if grep -q 'preferSessionLookupForAnnounceTarget' "$DISCORD" 2>/dev/null; then
    echo "SKIP #16812 discord: already patched"
    skipped=$((skipped + 1))
  else
    python3 - "$DISCORD" << 'PYEOF'
import sys
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

old = '''  meta: {
    ...meta,
  },
  onboarding: discordOnboardingAdapter,'''

new = '''  meta: {
    ...meta,
    preferSessionLookupForAnnounceTarget: true,
  },
  onboarding: discordOnboardingAdapter,'''

if old not in content:
    print(f"FAIL #16812 discord: could not find meta block in {filepath}")
    sys.exit(1)

content = content.replace(old, new, 1)
with open(filepath, 'w') as f:
    f.write(content)
print(f"OK #16812 discord: patched {filepath}")
PYEOF
    patched=$((patched + 1))
  fi
else
  echo "SKIP #16812 discord: $DISCORD not found"
  skipped=$((skipped + 1))
fi

# --- Signal ---
if [[ -f "$SIGNAL" ]]; then
  if grep -q 'preferSessionLookupForAnnounceTarget' "$SIGNAL" 2>/dev/null; then
    echo "SKIP #16812 signal: already patched"
    skipped=$((skipped + 1))
  else
    python3 - "$SIGNAL" << 'PYEOF'
import sys
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Signal plugin meta block — find the signalPlugin definition
# Need to find meta: { ...meta, } and add the flag
old = '''export const signalPlugin: ChannelPlugin<ResolvedSignalAccount>'''
if old not in content:
    print(f"FAIL #16812 signal: could not find signalPlugin export in {filepath}")
    sys.exit(1)

# Find the meta block after the signalPlugin export
# Pattern: meta: {\n    ...meta,\n  },
import re
pattern = r'(id:\s*"signal",\s*\n\s*meta:\s*\{\s*\n\s*\.\.\.meta,)\s*(\n\s*\},)'
match = re.search(pattern, content)
if not match:
    print(f"FAIL #16812 signal: could not find signal meta block in {filepath}")
    sys.exit(1)

replacement = match.group(1) + '\n    preferSessionLookupForAnnounceTarget: true,' + match.group(2)
content = content[:match.start()] + replacement + content[match.end():]

with open(filepath, 'w') as f:
    f.write(content)
print(f"OK #16812 signal: patched {filepath}")
PYEOF
    patched=$((patched + 1))
  fi
else
  echo "SKIP #16812 signal: $SIGNAL not found"
  skipped=$((skipped + 1))
fi

# --- Slack ---
if [[ -f "$SLACK" ]]; then
  if grep -q 'preferSessionLookupForAnnounceTarget' "$SLACK" 2>/dev/null; then
    echo "SKIP #16812 slack: already has preferSessionLookupForAnnounceTarget"
    skipped=$((skipped + 1))
  else
    python3 - "$SLACK" << 'PYEOF'
import sys
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

import re
pattern = r'(id:\s*"slack",\s*\n\s*meta:\s*\{\s*\n\s*\.\.\.meta,)\s*(\n\s*\},)'
match = re.search(pattern, content)
if not match:
    print(f"FAIL #16812 slack: could not find slack meta block in {filepath}")
    sys.exit(1)

replacement = match.group(1) + '\n    preferSessionLookupForAnnounceTarget: true,' + match.group(2)
content = content[:match.start()] + replacement + content[match.end():]

with open(filepath, 'w') as f:
    f.write(content)
print(f"OK #16812 slack: patched {filepath}")
PYEOF
    patched=$((patched + 1))
  fi
else
  echo "SKIP #16812 slack: $SLACK not found"
  skipped=$((skipped + 1))
fi

# --- Telegram ---
if [[ -f "$TELEGRAM" ]]; then
  if grep -q 'preferSessionLookupForAnnounceTarget' "$TELEGRAM" 2>/dev/null; then
    echo "SKIP #16812 telegram: already patched"
    skipped=$((skipped + 1))
  else
    python3 - "$TELEGRAM" << 'PYEOF'
import sys
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Telegram has: meta: { ...meta, quickstartAllowFrom: true, }
old = '''  meta: {
    ...meta,
    quickstartAllowFrom: true,
  },'''

new = '''  meta: {
    ...meta,
    quickstartAllowFrom: true,
    preferSessionLookupForAnnounceTarget: true,
  },'''

if old not in content:
    print(f"FAIL #16812 telegram: could not find telegram meta block in {filepath}")
    sys.exit(1)

content = content.replace(old, new, 1)
with open(filepath, 'w') as f:
    f.write(content)
print(f"OK #16812 telegram: patched {filepath}")
PYEOF
    patched=$((patched + 1))
  fi
else
  echo "SKIP #16812 telegram: $TELEGRAM not found"
  skipped=$((skipped + 1))
fi

echo "OK #16812: $patched patched, $skipped skipped"
