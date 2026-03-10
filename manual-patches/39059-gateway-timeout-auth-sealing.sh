#!/usr/bin/env bash
# PR #39059 — Security: harden gateway timeouts and auth store sealing
#
# Core changes:
# 1. sealed-json-file.ts: NEW FILE — AES-256-GCM encryption module for auth stores
#    (OPENCLAW_PASSPHRASE env var triggers sealing)
# 2. client.ts: Bounded request timeouts with cleanup for GatewayClient
# 3. store.ts: Switch auth store load/save to sealed variants + loadProtectedAuthJson
# 4. paths.ts: ensureAuthStoreFile uses saveSealedJsonFile
# 5. transcript.ts: Re-assert 0o600 permissions after transcript writes
#
# Skipped: test files, CHANGELOG.md, cosmetic/type-only changes
set -euo pipefail
SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if [ -f "$SRC/infra/sealed-json-file.ts" ] && \
   grep -q 'requestTimeoutMs' "$SRC/gateway/client.ts" 2>/dev/null; then
  echo "    SKIP: #39059 already applied"
  exit 0
fi

# ── File existence checks ──────────────────────────────────────────────────
[ -f "$SRC/gateway/client.ts" ]                    || { echo "    FAIL: $SRC/gateway/client.ts not found"; exit 1; }
[ -f "$SRC/agents/auth-profiles/store.ts" ]        || { echo "    FAIL: $SRC/agents/auth-profiles/store.ts not found"; exit 1; }
[ -f "$SRC/agents/auth-profiles/paths.ts" ]        || { echo "    FAIL: $SRC/agents/auth-profiles/paths.ts not found"; exit 1; }
[ -f "$SRC/config/sessions/transcript.ts" ]        || { echo "    FAIL: $SRC/config/sessions/transcript.ts not found"; exit 1; }

# ════════════════════════════════════════════════════════════════════════════
# 1) Create sealed-json-file.ts — AES-256-GCM encryption for auth stores
# ════════════════════════════════════════════════════════════════════════════
if [ -f "$SRC/infra/sealed-json-file.ts" ]; then
  echo "    SKIP: #39059 sealed-json-file.ts already exists"
else
  cat > "$SRC/infra/sealed-json-file.ts" << 'TSEOF'
import { randomBytes, createCipheriv, createDecipheriv, scryptSync } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const SEALED_JSON_PREFIX = "openclaw-sealed-json-v1:";

type SealedJsonEnvelope = {
  v: 1;
  alg: "aes-256-gcm";
  salt: string;
  iv: string;
  tag: string;
  ciphertext: string;
};

export class SealedJsonPassphraseRequiredError extends Error {
  constructor(pathname: string) {
    super(
      `Encrypted OpenClaw auth store at ${pathname} requires OPENCLAW_PASSPHRASE to be set before it can be read.`,
    );
    this.name = "SealedJsonPassphraseRequiredError";
  }
}

function resolvePassphrase(env: NodeJS.ProcessEnv = process.env): string | null {
  const value = env.OPENCLAW_PASSPHRASE?.trim();
  return value ? value : null;
}

function toBase64(value: Buffer): string {
  return value.toString("base64");
}

function fromBase64(value: string): Buffer {
  return Buffer.from(value, "base64");
}

function deriveKey(passphrase: string, salt: Buffer): Buffer {
  return scryptSync(passphrase, salt, 32);
}

function sealUtf8(plaintext: string, passphrase: string): string {
  const salt = randomBytes(16);
  const iv = randomBytes(12);
  const key = deriveKey(passphrase, salt);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const envelope: SealedJsonEnvelope = {
    v: 1,
    alg: "aes-256-gcm",
    salt: toBase64(salt),
    iv: toBase64(iv),
    tag: toBase64(cipher.getAuthTag()),
    ciphertext: toBase64(ciphertext),
  };
  return `${SEALED_JSON_PREFIX}${JSON.stringify(envelope)}\n`;
}

function unsealUtf8(raw: string, passphrase: string): string {
  if (!raw.startsWith(SEALED_JSON_PREFIX)) {
    return raw;
  }
  const payload = raw.slice(SEALED_JSON_PREFIX.length).trim();
  const envelope = JSON.parse(payload) as Partial<SealedJsonEnvelope>;
  if (
    envelope.v !== 1 ||
    envelope.alg !== "aes-256-gcm" ||
    typeof envelope.salt !== "string" ||
    typeof envelope.iv !== "string" ||
    typeof envelope.tag !== "string" ||
    typeof envelope.ciphertext !== "string"
  ) {
    throw new Error("invalid sealed json envelope");
  }
  const key = deriveKey(passphrase, fromBase64(envelope.salt));
  const decipher = createDecipheriv("aes-256-gcm", key, fromBase64(envelope.iv));
  decipher.setAuthTag(fromBase64(envelope.tag));
  return Buffer.concat([
    decipher.update(fromBase64(envelope.ciphertext)),
    decipher.final(),
  ]).toString("utf8");
}

export function loadSealedJsonFile(
  pathname: string,
  env: NodeJS.ProcessEnv = process.env,
): unknown {
  if (!fs.existsSync(pathname)) {
    return undefined;
  }
  const raw = fs.readFileSync(pathname, "utf8");
  if (!raw.startsWith(SEALED_JSON_PREFIX)) {
    return JSON.parse(raw) as unknown;
  }
  const passphrase = resolvePassphrase(env);
  if (!passphrase) {
    throw new SealedJsonPassphraseRequiredError(pathname);
  }
  return JSON.parse(unsealUtf8(raw, passphrase)) as unknown;
}

export function saveSealedJsonFile(
  pathname: string,
  data: unknown,
  env: NodeJS.ProcessEnv = process.env,
): void {
  const dir = path.dirname(pathname);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  }
  const plaintext = `${JSON.stringify(data, null, 2)}\n`;
  const passphrase = resolvePassphrase(env);
  fs.writeFileSync(pathname, passphrase ? sealUtf8(plaintext, passphrase) : plaintext, "utf8");
  fs.chmodSync(pathname, 0o600);
}

export function isSealedJsonText(raw: string): boolean {
  return raw.startsWith(SEALED_JSON_PREFIX);
}
TSEOF
  echo "    OK: #39059 sealed-json-file.ts created"
fi

# ════════════════════════════════════════════════════════════════════════════
# 2) client.ts: Add bounded request timeouts with cleanup
# ════════════════════════════════════════════════════════════════════════════
python3 - "$SRC/gateway/client.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

applied = 0

# 2a) Add cleanup field to Pending type
old_pending = '''  resolve: (value: unknown) => void;
  reject: (err: unknown) => void;
  expectFinal: boolean;'''

new_pending = '''  resolve: (value: unknown) => void;
  reject: (err: unknown) => void;
  expectFinal: boolean;
  cleanup?: () => void;'''

if 'cleanup?: () => void;' not in content:
    if old_pending in content:
        content = content.replace(old_pending, new_pending, 1)
        print("    OK: #39059 client.ts Pending type updated (+cleanup)")
        applied += 1
    else:
        print("    WARN: #39059 client.ts Pending type pattern not found")
else:
    print("    SKIP: #39059 client.ts Pending type already has cleanup")

# 2b) Add requestTimeoutMs to GatewayClientOptions
old_opts = '''  connectDelayMs?: number;
  tickWatchMinIntervalMs?: number;
  token?: string;'''

new_opts = '''  connectDelayMs?: number;
  tickWatchMinIntervalMs?: number;
  requestTimeoutMs?: number;
  token?: string;'''

if 'requestTimeoutMs?: number;' not in content:
    if old_opts in content:
        content = content.replace(old_opts, new_opts, 1)
        print("    OK: #39059 client.ts GatewayClientOptions updated (+requestTimeoutMs)")
        applied += 1
    else:
        print("    WARN: #39059 client.ts GatewayClientOptions pattern not found")
else:
    print("    SKIP: #39059 client.ts requestTimeoutMs already present")

# 2c) Add cleanup call in flushPendingErrors
old_flush = '''  private flushPendingErrors(err: Error) {
    for (const [, p] of this.pending) {
      p.reject(err);'''

new_flush = '''  private flushPendingErrors(err: Error) {
    for (const [, p] of this.pending) {
      p.cleanup?.();
      p.reject(err);'''

if 'p.cleanup?.();' not in content:
    if old_flush in content:
        content = content.replace(old_flush, new_flush, 1)
        print("    OK: #39059 client.ts flushPendingErrors updated (+cleanup)")
        applied += 1
    else:
        print("    WARN: #39059 client.ts flushPendingErrors pattern not found")
else:
    print("    SKIP: #39059 client.ts flushPendingErrors already has cleanup")

# 2d) Replace the request method signature and body with timeout support
old_request_sig = '''    method: string,
    params?: unknown,
    opts?: { expectFinal?: boolean },
  ): Promise<T> {'''

new_request_sig = '''    method: string,
    params?: unknown,
    opts?: { expectFinal?: boolean; timeoutMs?: number },
  ): Promise<T> {'''

if "timeoutMs?: number" not in content:
    if old_request_sig in content:
        content = content.replace(old_request_sig, new_request_sig, 1)
        print("    OK: #39059 client.ts request method signature updated (+timeoutMs)")
        applied += 1
    else:
        print("    WARN: #39059 client.ts request method signature pattern not found")
else:
    print("    SKIP: #39059 client.ts request signature already has timeoutMs")

# 2e) Add timeout logic after expectFinal assignment, replace promise creation + send
old_promise_block = '''    const expectFinal = opts?.expectFinal === true;
    const p = new Promise<T>((resolve, reject) => {
      this.pending.set(id, {
        resolve: (value) => resolve(value as T),
        reject,
        expectFinal,
      });
    });
    this.ws.send(JSON.stringify(frame));
    return p;'''

new_promise_block = '''    const expectFinal = opts?.expectFinal === true;
    const rawTimeoutMs = opts?.timeoutMs ?? this.opts.requestTimeoutMs;
    const timeoutMs =
      typeof rawTimeoutMs === "number" && Number.isFinite(rawTimeoutMs)
        ? Math.max(1, Math.min(300_000, rawTimeoutMs))
        : 30_000;
    const p = new Promise<T>((resolve, reject) => {
      let timeout: NodeJS.Timeout | null = setTimeout(() => {
        timeout = null;
        this.pending.delete(id);
        reject(new Error(`gateway request timeout for ${method}`));
      }, timeoutMs);
      timeout.unref?.();
      const cleanup = () => {
        if (!timeout) {
          return;
        }
        clearTimeout(timeout);
        timeout = null;
      };
      this.pending.set(id, {
        resolve: (value) => {
          cleanup();
          resolve(value as T);
        },
        reject: (err) => {
          cleanup();
          reject(err);
        },
        expectFinal,
        cleanup,
      });
    });
    try {
      this.ws.send(JSON.stringify(frame));
    } catch (err) {
      const pending = this.pending.get(id);
      pending?.cleanup?.();
      this.pending.delete(id);
      throw err;
    }
    return p;'''

if 'gateway request timeout for' not in content:
    if old_promise_block in content:
        content = content.replace(old_promise_block, new_promise_block, 1)
        print("    OK: #39059 client.ts request method body updated (timeout + cleanup)")
        applied += 1
    else:
        print("    WARN: #39059 client.ts request body pattern not found — may need manual review")
else:
    print("    SKIP: #39059 client.ts request timeout already present")

with open(path, 'w') as f:
    f.write(content)
print(f"    __APPLIED_CLIENT:{applied}")
PYEOF

# ════════════════════════════════════════════════════════════════════════════
# 3) store.ts: Switch auth store to sealed load/save + add loadProtectedAuthJson
# ════════════════════════════════════════════════════════════════════════════
python3 - "$SRC/agents/auth-profiles/store.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

applied = 0

# 3a) Update imports: add sealed imports alongside existing loadJsonFile
old_import = 'import { loadJsonFile, saveJsonFile } from "../../infra/json-file.js";'
new_import = '''import { loadJsonFile } from "../../infra/json-file.js";
import {
  SealedJsonPassphraseRequiredError,
  loadSealedJsonFile,
  saveSealedJsonFile,
} from "../../infra/sealed-json-file.js";'''

if 'sealed-json-file.js' not in content:
    if old_import in content:
        content = content.replace(old_import, new_import, 1)
        print("    OK: #39059 store.ts imports updated (+sealed)")
        applied += 1
    else:
        print("    WARN: #39059 store.ts import pattern not found")
else:
    print("    SKIP: #39059 store.ts sealed imports already present")

# 3b) Add loadProtectedAuthJson function after resolveRuntimeStoreKey
old_after_key = '''  return resolveAuthStorePath(agentDir);
}

function cloneAuthProfileStore'''

new_after_key = '''  return resolveAuthStorePath(agentDir);
}

function loadProtectedAuthJson(pathname: string, label: string): unknown {
  try {
    return loadSealedJsonFile(pathname);
  } catch (err) {
    if (err instanceof SealedJsonPassphraseRequiredError) {
      log.warn(`${label} is encrypted but OPENCLAW_PASSPHRASE is not set`, { pathname });
      return undefined;
    }
    log.warn(`failed to load ${label}`, { pathname, err });
    return undefined;
  }
}

function cloneAuthProfileStore'''

if 'loadProtectedAuthJson' not in content:
    if old_after_key in content:
        content = content.replace(old_after_key, new_after_key, 1)
        print("    OK: #39059 store.ts loadProtectedAuthJson added")
        applied += 1
    else:
        print("    WARN: #39059 store.ts resolveRuntimeStoreKey/cloneAuthProfileStore pattern not found")
else:
    print("    SKIP: #39059 store.ts loadProtectedAuthJson already present")

# 3c) Replace loadJsonFile(oauthPath) with loadProtectedAuthJson in mergeOAuthFileIntoStore
old_oauth = '  const oauthRaw = loadJsonFile(oauthPath);'
new_oauth = '  const oauthRaw = loadProtectedAuthJson(oauthPath, "oauth.json");'

if 'loadProtectedAuthJson(oauthPath' not in content:
    if old_oauth in content:
        content = content.replace(old_oauth, new_oauth, 1)
        print("    OK: #39059 store.ts mergeOAuthFileIntoStore updated (sealed load)")
        applied += 1
    else:
        print("    WARN: #39059 store.ts oauthPath loadJsonFile pattern not found")
else:
    print("    SKIP: #39059 store.ts oauthPath already uses sealed load")

# 3d) Replace loadJsonFile(authPath) with loadProtectedAuthJson in loadCoercedStore
old_coerced = '  const raw = loadJsonFile(authPath);'
new_coerced = '  const raw = loadProtectedAuthJson(authPath, "auth-profiles.json");'

if 'loadProtectedAuthJson(authPath' not in content:
    if old_coerced in content:
        content = content.replace(old_coerced, new_coerced, 1)
        print("    OK: #39059 store.ts loadCoercedStore updated (sealed load)")
        applied += 1
    else:
        print("    WARN: #39059 store.ts loadCoercedStore loadJsonFile pattern not found")
else:
    print("    SKIP: #39059 store.ts loadCoercedStore already uses sealed load")

# 3e) Replace all saveJsonFile(authPath, ...) with saveSealedJsonFile
# There are 5 occurrences in the file, all should be switched
import re
count = content.count('saveJsonFile(authPath,')
if count > 0:
    content = content.replace('saveJsonFile(authPath,', 'saveSealedJsonFile(authPath,')
    print(f"    OK: #39059 store.ts replaced {count}x saveJsonFile -> saveSealedJsonFile")
    applied += 1
else:
    if 'saveSealedJsonFile(authPath,' in content:
        print("    SKIP: #39059 store.ts already uses saveSealedJsonFile")
    else:
        print("    WARN: #39059 store.ts no saveJsonFile(authPath, ...) found")

with open(path, 'w') as f:
    f.write(content)
print(f"    __APPLIED_STORE:{applied}")
PYEOF

# ════════════════════════════════════════════════════════════════════════════
# 4) paths.ts: ensureAuthStoreFile uses saveSealedJsonFile
# ════════════════════════════════════════════════════════════════════════════
python3 - "$SRC/agents/auth-profiles/paths.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

applied = 0

# 4a) Replace import
old_import = 'import { saveJsonFile } from "../../infra/json-file.js";'
new_import = 'import { saveSealedJsonFile } from "../../infra/sealed-json-file.js";'

if 'sealed-json-file.js' not in content:
    if old_import in content:
        content = content.replace(old_import, new_import, 1)
        print("    OK: #39059 paths.ts import updated (json-file -> sealed-json-file)")
        applied += 1
    else:
        print("    WARN: #39059 paths.ts import pattern not found")
else:
    print("    SKIP: #39059 paths.ts sealed import already present")

# 4b) Replace saveJsonFile call
old_save = '  saveJsonFile(pathname, payload);'
new_save = '  saveSealedJsonFile(pathname, payload);'

if 'saveSealedJsonFile(pathname, payload)' not in content:
    if old_save in content:
        content = content.replace(old_save, new_save, 1)
        print("    OK: #39059 paths.ts ensureAuthStoreFile updated (sealed save)")
        applied += 1
    else:
        print("    WARN: #39059 paths.ts saveJsonFile call pattern not found")
else:
    print("    SKIP: #39059 paths.ts already uses saveSealedJsonFile")

with open(path, 'w') as f:
    f.write(content)
print(f"    __APPLIED_PATHS:{applied}")
PYEOF

# ════════════════════════════════════════════════════════════════════════════
# 5) transcript.ts: Re-assert 0o600 permissions after transcript writes
# ════════════════════════════════════════════════════════════════════════════
python3 - "$SRC/config/sessions/transcript.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

applied = 0

# 5a) Add hardenSessionFilePermissions function after ensureSessionHeader closing brace
# Look for the pattern right before appendAssistantMessageToSessionTranscript
old_before_append = '''export async function appendAssistantMessageToSessionTranscript(params: {'''

harden_fn = '''async function hardenSessionFilePermissions(sessionFile: string): Promise<void> {
  try {
    await fs.promises.chmod(sessionFile, 0o600);
  } catch {
    // Best-effort on platforms without POSIX chmod support.
  }
}

export async function appendAssistantMessageToSessionTranscript(params: {'''

if 'hardenSessionFilePermissions' not in content:
    if old_before_append in content:
        content = content.replace(old_before_append, harden_fn, 1)
        print("    OK: #39059 transcript.ts hardenSessionFilePermissions added")
        applied += 1
    else:
        print("    WARN: #39059 transcript.ts appendAssistantMessage pattern not found")
else:
    print("    SKIP: #39059 transcript.ts hardenSessionFilePermissions already present")

# 5b) Add call to hardenSessionFilePermissions after the appendJsonLine for stopReason
old_stop = '''    stopReason: "stop",
    timestamp: Date.now(),
  });

  emitSessionTranscriptUpdate(sessionFile);'''

new_stop = '''    stopReason: "stop",
    timestamp: Date.now(),
  });
  await hardenSessionFilePermissions(sessionFile);

  emitSessionTranscriptUpdate(sessionFile);'''

if 'hardenSessionFilePermissions(sessionFile)' not in content:
    if old_stop in content:
        content = content.replace(old_stop, new_stop, 1)
        print("    OK: #39059 transcript.ts chmod call added after transcript write")
        applied += 1
    else:
        print("    WARN: #39059 transcript.ts stopReason/emit pattern not found")
else:
    print("    SKIP: #39059 transcript.ts chmod call already present")

with open(path, 'w') as f:
    f.write(content)
print(f"    __APPLIED_TRANSCRIPT:{applied}")
PYEOF

echo "    OK: #39059 gateway timeout + auth store sealing applied"
