#!/usr/bin/env bash
# PR #16987 - fix(config): skipCache sessionStore prevent lost updates
# When holding a session store lock, re-reading from disk (skipCache: true)
# prevents clobbering writes made by concurrent processes.
# updateSessionStoreEntry already had this fix; this adds it to updateLastRoute.
set -euo pipefail
cd "$1"

FILE="src/config/sessions/store.ts"

# In updateLastRoute, replace loadSessionStore(storePath) with skipCache variant.
# We target the specific pattern inside updateLastRoute (after withSessionStoreLock).
# The function is identified by the surrounding context.
python3 -c "
import re
with open('$FILE', 'r') as f:
    content = f.read()

# Find updateLastRoute function and fix the loadSessionStore call inside it
# Pattern: inside withSessionStoreLock callback, loadSessionStore without skipCache
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
