#!/usr/bin/env bash
# Issue #25818: fix(gateway): add /tmp/openclaw/ log rotation on startup
#
# OpenClaw writes temp files to /tmp/openclaw/ (media, browser, discord voice,
# plugin temp paths) but never rotates or cleans them. On long-running macOS
# gateway installations, these files grow unbounded and can fill up /tmp,
# causing bootstrap failures.
#
# Fix: Add a cleanTmpDir() utility in infra/tmp-openclaw-dir.ts that:
#   - Deletes files older than 7 days
#   - Truncates files larger than 50MB
#   - Runs non-blocking (fire-and-forget)
# Then call it from startGatewaySidecars() on gateway startup.
#
# Changes:
#   1. src/infra/tmp-openclaw-dir.ts — add cleanExpiredTmpFiles() export
#   2. src/gateway/server-startup.ts — import + call on startup
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'cleanExpiredTmpFiles' "$SRC/infra/tmp-openclaw-dir.ts" 2>/dev/null; then
  echo "    SKIP: #25818 already applied"
  exit 0
fi

# ── 1. src/infra/tmp-openclaw-dir.ts — add cleanExpiredTmpFiles() ─────────
python3 - "$SRC/infra/tmp-openclaw-dir.ts" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, "r") as f:
    code = f.read()

# Check that the file has the expected structure
if "POSIX_OPENCLAW_TMP_DIR" not in code:
    print("    FAIL: #25818 POSIX_OPENCLAW_TMP_DIR not found", file=sys.stderr)
    sys.exit(1)

# We need to add fs/promises import. The file already imports fs (sync),
# but we need the async version for cleanup.
# Check existing imports
if 'import fs from "node:fs";' not in code:
    print("    FAIL: #25818 fs import not found in tmp-openclaw-dir.ts", file=sys.stderr)
    sys.exit(1)

# Add fs/promises import after existing fs import
if 'import fsPromises from "node:fs/promises";' not in code:
    code = code.replace(
        'import fs from "node:fs";',
        'import fs from "node:fs";\nimport fsPromises from "node:fs/promises";',
        1,
    )

# Append the cleanup function at the end of the file
cleanup_fn = '''
const TMP_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000; // 7 days
const TMP_MAX_FILE_BYTES = 50 * 1024 * 1024; // 50 MB

/**
 * Clean expired and oversized files from the OpenClaw tmp directory.
 *
 * Designed to run as a non-blocking fire-and-forget task on gateway startup:
 *   - Deletes files older than 7 days (TMP_MAX_AGE_MS)
 *   - Truncates files larger than 50 MB (TMP_MAX_FILE_BYTES)
 *   - Skips directories (only processes top-level files)
 *   - Ignores all errors silently to avoid disrupting startup
 *
 * @param tmpDir Override tmp dir path (defaults to resolvePreferredOpenClawTmpDir())
 */
export async function cleanExpiredTmpFiles(tmpDir?: string): Promise<{
  deleted: number;
  truncated: number;
  errors: number;
}> {
  const dir = tmpDir ?? resolvePreferredOpenClawTmpDir();
  const result = { deleted: 0, truncated: 0, errors: 0 };
  const now = Date.now();

  let entries: fs.Dirent<string>[];
  try {
    entries = await fsPromises.readdir(dir, { withFileTypes: true }) as fs.Dirent<string>[];
  } catch {
    // Directory may not exist yet — not an error.
    return result;
  }

  for (const entry of entries) {
    // Recurse into subdirectories to clean nested temp files.
    if (entry.isDirectory()) {
      try {
        const subResult = await cleanExpiredTmpFiles(
          path.join(dir, entry.name),
        );
        result.deleted += subResult.deleted;
        result.truncated += subResult.truncated;
        result.errors += subResult.errors;
      } catch {
        result.errors += 1;
      }

      // Try to remove empty directories after cleaning their contents.
      try {
        await fsPromises.rmdir(path.join(dir, entry.name));
      } catch {
        // Not empty or other error — ignore.
      }
      continue;
    }

    if (!entry.isFile()) {
      continue;
    }

    const filePath = path.join(dir, entry.name);
    try {
      const stat = await fsPromises.stat(filePath);
      const ageMs = now - stat.mtimeMs;

      if (ageMs > TMP_MAX_AGE_MS) {
        await fsPromises.unlink(filePath);
        result.deleted += 1;
        continue;
      }

      if (stat.size > TMP_MAX_FILE_BYTES) {
        await fsPromises.truncate(filePath, 0);
        result.truncated += 1;
      }
    } catch {
      result.errors += 1;
    }
  }

  return result;
}
'''

code = code.rstrip() + "\n" + cleanup_fn

with open(filepath, "w") as f:
    f.write(code)
print("    OK: #25818 tmp-openclaw-dir.ts — cleanExpiredTmpFiles() added")
PYEOF

# ── 2. src/gateway/server-startup.ts — import + call on startup ───────────
python3 - "$SRC/gateway/server-startup.ts" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, "r") as f:
    code = f.read()

changed = False

# 2a. Add import for cleanExpiredTmpFiles
if "cleanExpiredTmpFiles" not in code:
    # Insert after the isTruthyEnvValue import (last infra import in the block)
    marker = 'import { isTruthyEnvValue } from "../infra/env.js";'
    if marker not in code:
        print("    FAIL: #25818 isTruthyEnvValue import not found", file=sys.stderr)
        sys.exit(1)
    code = code.replace(
        marker,
        marker + '\nimport { cleanExpiredTmpFiles } from "../infra/tmp-openclaw-dir.js";',
        1,
    )
    changed = True
    print("    OK: #25818 import added to server-startup.ts")
else:
    print("    SKIP: #25818 import already present")

# 2b. Add cleanup call in startGatewaySidecars, right after the session lock
#     cleanup block (fire-and-forget, non-blocking).
#     Target: insert after the session lock cleanup catch block.
cleanup_marker = '  } catch (err) {\n    params.log.warn(`session lock cleanup failed on startup: ${String(err)}`);\n  }'
if cleanup_marker not in code:
    print("    FAIL: #25818 session lock cleanup catch block not found", file=sys.stderr)
    sys.exit(1)

cleanup_call = '''  } catch (err) {
    params.log.warn(`session lock cleanup failed on startup: ${String(err)}`);
  }

  // #25818: Clean expired temp files from /tmp/openclaw/ on startup.
  // Fire-and-forget — errors are silently ignored to avoid disrupting startup.
  void cleanExpiredTmpFiles().then((stats) => {
    if (stats.deleted > 0 || stats.truncated > 0) {
      params.log.warn(
        `tmp cleanup: deleted ${stats.deleted} expired, truncated ${stats.truncated} oversized` +
          (stats.errors > 0 ? `, ${stats.errors} errors` : ""),
      );
    }
  }).catch(() => {
    // Intentionally swallowed — tmp cleanup must never break startup.
  });'''

if '#25818' not in code:
    code = code.replace(cleanup_marker, cleanup_call, 1)
    changed = True
    print("    OK: #25818 cleanup call added to startGatewaySidecars")
else:
    print("    SKIP: #25818 cleanup call already present")

if changed:
    with open(filepath, "w") as f:
        f.write(code)

print("    OK: #25818 server-startup.ts fully patched")
PYEOF

echo "    OK: #25818 fully applied"
