#!/usr/bin/env bash
# PR #17435 - fix(debounce): retry flush with exponential backoff
# When the session store lock is held (e.g. by a cron job), flush failures
# could silently drop messages. This adds retry with exponential backoff.
set -euo pipefail
cd "$1"

FILE="src/auto-reply/inbound-debounce.ts"

python3 -c "
with open('$FILE', 'r') as f:
    content = f.read()

# 1. Add constants and new params before createInboundDebouncer
old_create = 'export function createInboundDebouncer<T>(params: {'
new_create = '''const DEFAULT_RETRY_ATTEMPTS = 3;
const DEFAULT_RETRY_BASE_MS = 500;

export function createInboundDebouncer<T>(params: {'''
content = content.replace(old_create, new_create, 1)

# 2. Add retryAttempts and retryBaseMs params
old_params = '''  onFlush: (items: T[]) => Promise<void>;
  onError?: (err: unknown, items: T[]) => void;'''
new_params = '''  onFlush: (items: T[]) => Promise<void>;
  onError?: (err: unknown, items: T[]) => void;
  /** Max retry attempts when flush fails (default: 3). */
  retryAttempts?: number;
  /** Base delay in ms for exponential backoff (default: 500). */
  retryBaseMs?: number;'''
content = content.replace(old_params, new_params, 1)

# 3. Add retry variables after defaultDebounceMs
old_default = '  const defaultDebounceMs = Math.max(0, Math.trunc(params.debounceMs));'
new_default = '''  const defaultDebounceMs = Math.max(0, Math.trunc(params.debounceMs));
  const retryAttempts = params.retryAttempts ?? DEFAULT_RETRY_ATTEMPTS;
  const retryBaseMs = params.retryBaseMs ?? DEFAULT_RETRY_BASE_MS;

  const delay = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));'''
content = content.replace(old_default, new_default, 1)

# 4. Replace try/catch in flushBuffer with retry loop
old_flush = '''    if (buffer.items.length === 0) {
      return;
    }
    try {
      await params.onFlush(buffer.items);
    } catch (err) {
      params.onError?.(err, buffer.items);
    }'''
new_flush = '''    if (buffer.items.length === 0) {
      return;
    }
    // Retry with exponential backoff when flush fails (e.g. session store
    // lock contention).  This prevents silent message loss when a cron job
    // or other operation holds the lock temporarily.
    // See: https://github.com/openclaw/openclaw/issues/17421
    let lastErr: unknown;
    for (let attempt = 0; attempt <= retryAttempts; attempt++) {
      try {
        await params.onFlush(buffer.items);
        return;
      } catch (err) {
        lastErr = err;
        if (attempt < retryAttempts) {
          await delay(retryBaseMs * 2 ** attempt);
        }
      }
    }
    params.onError?.(lastErr, buffer.items);'''
content = content.replace(old_flush, new_flush, 1)

# 5. Replace immediate onFlush with flushBuffer call
old_immediate = '      await params.onFlush([item]);'
new_immediate = '      // Route non-debounced messages (media, control commands) through\\n      // flushBuffer so they also benefit from retry-on-lock-contention.\\n      await flushBuffer(\"__immediate__\", { items: [item], timeout: null, debounceMs: 0 });'
content = content.replace(old_immediate, new_immediate, 1)

with open('$FILE', 'w') as f:
    f.write(content)
print('Applied PR #17435 - debounce retry with exponential backoff')
"
