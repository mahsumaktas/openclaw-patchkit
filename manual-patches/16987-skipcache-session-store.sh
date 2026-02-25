#!/usr/bin/env bash
# PR #16987 - fix(config): skipCache sessionStore prevent lost updates
# When holding a session store lock, re-reading from disk (skipCache: true)
# prevents clobbering writes made by concurrent processes.
# updateSessionStoreEntry already had this fix; this adds it to updateLastRoute.
set -euo pipefail
cd "$1"

FILE="src/config/sessions/store.ts"

# In updateLastRoute, replace loadSessionStore(storePath) with skipCache variant.
python3 -c "
import re
with open('$FILE', 'r') as f:
    content = f.read()

old = '''return await withSessionStoreLock(storePath, async () => {
    const store = loadSessionStore(storePath);
    const existing = store[sessionKey];
    const now = Date.now();
    const explicitContext = normalizeDeliveryContext'''

new = '''return await withSessionStoreLock(storePath, async () => {
    // Always re-read inside the lock to avoid clobbering concurrent writers.
    const store = loadSessionStore(storePath, { skipCache: true });
    const existing = store[sessionKey];
    const now = Date.now();
    const explicitContext = normalizeDeliveryContext'''

if old in content:
    content = content.replace(old, new, 1)
    with open('$FILE', 'w') as f:
        f.write(content)
    print('Applied PR #16987 - skipCache in updateLastRoute')
else:
    print('SKIP: context not found or already applied')
"
