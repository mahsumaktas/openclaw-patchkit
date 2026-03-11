#!/usr/bin/env bash
# PR #32267 — fix(memory): Don't fallback to builtin when QMD is explicitly configured
# 1 file: memory/search-manager.ts (tests skipped)
#
# Problem: When QMD is explicitly configured but fails, the system silently falls back
# to the builtin (cloud-based) embedding search. Users choose QMD specifically to
# avoid cloud dependencies, so this fallback breaks expectations.
#
# Fix: Remove FallbackMemoryManager class, use QMD directly, return explicit error
# messages when QMD fails instead of silently falling back.
set -euo pipefail
SRC="${1:-.}/src"

MANAGER="$SRC/memory/search-manager.ts"

# ── Idempotency ──
if grep -q 'not falling back to builtin as QMD is explicitly configured' "$MANAGER" 2>/dev/null; then
  echo "    SKIP: #32267 already applied"
  exit 0
fi

# ── File checks ──
[ -f "$MANAGER" ] || { echo "    FAIL: #32267 $MANAGER not found"; exit 1; }

python3 - "$MANAGER" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Part 1: Fix imports — remove unused MemoryEmbeddingProbeResult, MemorySyncProgressUpdate
old_imports = '''import type {
  MemoryEmbeddingProbeResult,
  MemorySearchManager,
  MemorySyncProgressUpdate,
} from "./types.js";'''

new_imports = '''import type { MemorySearchManager } from "./types.js";'''

if old_imports not in content:
    print("    FAIL: #32267 cannot find import block", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_imports, new_imports, 1)

# Part 2: Replace the QMD wrapper + fallback with direct QMD usage
old_qmd = '''      if (primary) {
        if (statusOnly) {
          return { manager: primary };
        }
        const wrapper = new FallbackMemoryManager(
          {
            primary,
            fallbackFactory: async () => {
              const { MemoryIndexManager } = await loadManagerRuntime();
              return await MemoryIndexManager.get(params);
            },
          },
          () => {
            if (cacheKey) {
              QMD_MANAGER_CACHE.delete(cacheKey);
            }
          },
        );
        if (cacheKey) {
          QMD_MANAGER_CACHE.set(cacheKey, wrapper);
        }
        return { manager: wrapper };
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      log.warn(`qmd memory unavailable; falling back to builtin: ${message}`);
    }'''

new_qmd = '''      if (primary) {
        if (statusOnly) {
          return { manager: primary };
        }
        // When QMD is explicitly configured, we use QMD directly without fallback.
        // Users choose QMD specifically to avoid cloud embedding dependencies.
        // Falling back to builtin (which requires cloud providers) breaks that expectation.
        // See: https://github.com/openclaw/openclaw/issues/12021
        if (cacheKey) {
          QMD_MANAGER_CACHE.set(cacheKey, primary);
        }
        return { manager: primary };
      }
      // QMD was explicitly configured but returned null - don't fall back to builtin
      log.error(`QMD memory backend returned null (not falling back to builtin as QMD is explicitly configured)`);
      return { manager: null, error: `QMD backend returned null` };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      // When QMD is explicitly configured, don't silently fall back to builtin.
      // Return the actual QMD error so users know their chosen backend failed.
      log.error(`QMD memory backend failed (not falling back to builtin as QMD is explicitly configured): ${message}`);
      return { manager: null, error: `QMD backend error: ${message}` };
    }'''

if old_qmd not in content:
    print("    FAIL: #32267 cannot find QMD wrapper block", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_qmd, new_qmd, 1)

# Part 3: Remove the entire FallbackMemoryManager class
class_start = content.find('\nclass FallbackMemoryManager')
if class_start < 0:
    print("    FAIL: #32267 cannot find FallbackMemoryManager class", file=sys.stderr)
    sys.exit(1)

# Find the end of the class — look for the closing brace of evictCacheEntry method
# Pattern: private evictCacheEntry ... \n  }\n}
class_end_marker = '  private evictCacheEntry(): void {'
marker_pos = content.find(class_end_marker, class_start)
if marker_pos < 0:
    print("    FAIL: #32267 cannot find evictCacheEntry", file=sys.stderr)
    sys.exit(1)

# Find the closing of evictCacheEntry method and class
# The pattern is:  }\n}\n
pos = marker_pos
brace_count = 0
found_end = -1
for i in range(pos, len(content)):
    if content[i] == '{':
        brace_count += 1
    elif content[i] == '}':
        brace_count -= 1
        if brace_count == 0:
            # This closes evictCacheEntry
            # Look for the next } which closes the class
            j = i + 1
            while j < len(content) and content[j] in ' \t\n':
                j += 1
            if j < len(content) and content[j] == '}':
                found_end = j + 1
                break

if found_end < 0:
    print("    FAIL: #32267 cannot find end of FallbackMemoryManager class", file=sys.stderr)
    sys.exit(1)

content = content[:class_start] + content[found_end:]

with open(path, 'w') as f:
    f.write(content)
print("    OK: #32267 search-manager.ts — FallbackMemoryManager removed, QMD direct usage")
PYEOF

echo "    OK: #32267 QMD no builtin fallback applied"
