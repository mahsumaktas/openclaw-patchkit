#!/usr/bin/env bash
# PR #21847 - fix(session): /new and /reset no longer carry model overrides
# When a user resets their session with /new or /reset, UX preferences
# (verbose, thinking, ttsAuto) should carry over, but model/provider
# overrides should NOT, so the user starts fresh with default model.
set -euo pipefail
cd "$1"

FILE="src/auto-reply/reply/session.ts"

# Remove the two lines that carry over model overrides during reset
python3 -c "
with open('$FILE', 'r') as f:
    lines = f.readlines()

# Find and remove the two persistedModelOverride/persistedProviderOverride lines
# inside the reset block (resetTriggered && entry)
output = []
skip_next = False
for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped == 'persistedModelOverride = entry.modelOverride;' or \
       stripped == 'persistedProviderOverride = entry.providerOverride;':
        # Check we're in the resetTriggered block by looking for context
        in_reset = any('resetTriggered' in lines[max(0,j)] for j in range(max(0,i-10), i))
        if in_reset:
            continue
    output.append(line)

with open('$FILE', 'w') as f:
    f.writelines(output)
print('Applied PR #21847 - session model overrides not carried on reset')
"
