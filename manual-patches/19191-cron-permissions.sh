#!/usr/bin/env bash
# PR #19191 - fix(security): harden cron file permissions to 0o600
# Adds mode: 0o600 to cron file writes and 0o700 to cron directory creation.
# Also adds chmodCronState() to security/fix.ts for retroactive hardening.
set -euo pipefail
cd "$1"

CHANGED=0

# ── File 1: src/cron/run-log.ts ──────────────────────────────────────────────
FILE="src/cron/run-log.ts"
if [ ! -f "$FILE" ]; then
  echo "SKIP: $FILE not found"
else
  # Hunk 1: writeFile tmp with mode: 0o600
  if grep -q 'mode: 0o600' "$FILE" 2>/dev/null; then
    echo "OK: $FILE already patched"
  else
    # writeFile(tmp, ..., "utf-8") → writeFile(tmp, ..., { encoding: "utf-8", mode: 0o600 })
    sed -i.bak 's|await fs.writeFile(tmp, `${kept.join("\\n")}\\n`, "utf-8");|await fs.writeFile(tmp, `${kept.join("\\n")}\\n`, { encoding: "utf-8", mode: 0o600 });|' "$FILE"

    # mkdir with mode: 0o700
    sed -i.bak 's|await fs.mkdir(path.dirname(resolved), { recursive: true });|await fs.mkdir(path.dirname(resolved), { recursive: true, mode: 0o700 });|' "$FILE"

    # appendFile(resolved, ..., "utf-8") → appendFile with mode
    python3 -c "
import re
with open('$FILE', 'r') as f:
    content = f.read()
old = 'await fs.appendFile(resolved, \`\${JSON.stringify(entry)}\\\\n\`, \"utf-8\");'
new = '''await fs.appendFile(resolved, \`\${JSON.stringify(entry)}\\\\n\`, {
        encoding: \"utf-8\",
        mode: 0o600,
      });'''
if old in content:
    content = content.replace(old, new, 1)
    with open('$FILE', 'w') as f:
        f.write(content)
    print('OK: run-log.ts patched (writeFile + mkdir + appendFile)')
else:
    print('SKIP: appendFile pattern not found in run-log.ts')
"
    rm -f "${FILE}.bak"
    CHANGED=$((CHANGED + 1))
  fi
fi

# ── File 2: src/cron/store.ts ────────────────────────────────────────────────
FILE="src/cron/store.ts"
if [ ! -f "$FILE" ]; then
  echo "SKIP: $FILE not found"
else
  if grep -q 'mode: 0o700' "$FILE" 2>/dev/null; then
    echo "OK: $FILE already patched"
  else
    # mkdir with mode: 0o700
    sed -i.bak 's|await fs.promises.mkdir(path.dirname(storePath), { recursive: true });|await fs.promises.mkdir(path.dirname(storePath), { recursive: true, mode: 0o700 });|' "$FILE"

    # writeFile with mode: 0o600
    sed -i.bak 's|await fs.promises.writeFile(tmp, json, "utf-8");|await fs.promises.writeFile(tmp, json, { encoding: "utf-8", mode: 0o600 });|' "$FILE"

    # Add chmod after copyFile
    python3 -c "
with open('$FILE', 'r') as f:
    content = f.read()
old = '''await fs.promises.copyFile(storePath, \`\${storePath}.bak\`);
  } catch {'''
new = '''await fs.promises.copyFile(storePath, \`\${storePath}.bak\`);
    await fs.promises.chmod(\`\${storePath}.bak\`, 0o600);
  } catch {'''
if 'chmod' not in content and old in content:
    content = content.replace(old, new, 1)
    with open('$FILE', 'w') as f:
        f.write(content)
    print('OK: store.ts patched (mkdir + writeFile + chmod)')
elif 'chmod' in content:
    print('SKIP: store.ts already has chmod')
else:
    print('WARN: store.ts pattern not found')
"
    rm -f "${FILE}.bak"
    CHANGED=$((CHANGED + 1))
  fi
fi

# ── File 3: src/security/fix.ts ──────────────────────────────────────────────
FILE="src/security/fix.ts"
if [ ! -f "$FILE" ]; then
  echo "SKIP: $FILE not found"
else
  if grep -q 'chmodCronState' "$FILE" 2>/dev/null; then
    echo "OK: $FILE already patched"
  else
    python3 -c "
with open('$FILE', 'r') as f:
    content = f.read()

# 1. Add chmodCronState function after chmodCredentialsAndAgentState
func_marker = 'export async function fixSecurityFootguns'
cron_func = '''async function chmodCronState(params: {
  stateDir: string;
  actions: SecurityFixAction[];
  applyPerms: (params: {
    path: string;
    mode: number;
    require: \"dir\" | \"file\";
  }) => Promise<SecurityFixAction>;
}): Promise<void> {
  const cronDir = path.join(params.stateDir, \"cron\");
  params.actions.push(await params.applyPerms({ path: cronDir, mode: 0o700, require: \"dir\" }));

  const jobsPath = path.join(cronDir, \"jobs.json\");
  params.actions.push(await params.applyPerms({ path: jobsPath, mode: 0o600, require: \"file\" }));

  const jobsBakPath = path.join(cronDir, \"jobs.json.bak\");
  params.actions.push(await params.applyPerms({ path: jobsBakPath, mode: 0o600, require: \"file\" }));

  const runsDir = path.join(cronDir, \"runs\");
  params.actions.push(await params.applyPerms({ path: runsDir, mode: 0o700, require: \"dir\" }));

  const runEntries = await fs.readdir(runsDir, { withFileTypes: true }).catch(() => []);
  for (const entry of runEntries) {
    if (!entry.isFile()) {
      continue;
    }
    if (!entry.name.endsWith(\".jsonl\")) {
      continue;
    }
    const p = path.join(runsDir, entry.name);
    // eslint-disable-next-line no-await-in-loop
    params.actions.push(await params.applyPerms({ path: p, mode: 0o600, require: \"file\" }));
  }
}

'''

if func_marker in content:
    content = content.replace(func_marker, cron_func + func_marker, 1)

# 2. Add chmodCronState call after chmodCredentialsAndAgentState call
call_marker = 'errors.push(\`chmodCredentialsAndAgentState failed: \${String(err)}\`);'
call_end = '});'
cron_call = '''

  // Harden cron directory and its sensitive files (jobs.json, run logs).
  await chmodCronState({ stateDir, actions, applyPerms }).catch((err) => {
    errors.push(\`chmodCronState failed: \${String(err)}\`);
  });'''

# Find the position after the chmodCredentialsAndAgentState catch block
import re
pattern = re.escape(call_marker) + r'\\s*\\n\\s*' + re.escape(call_end)
match = re.search(pattern, content)
if match:
    insert_pos = match.end()
    content = content[:insert_pos] + cron_call + content[insert_pos:]

with open('$FILE', 'w') as f:
    f.write(content)
print('OK: fix.ts patched (chmodCronState function + call)')
"
    CHANGED=$((CHANGED + 1))
  fi
fi

echo "Applied PR #19191 - cron file permissions hardening ($CHANGED files changed)"
