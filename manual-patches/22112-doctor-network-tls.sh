#!/usr/bin/env bash
# PR #22112 - fix(doctor): warn when gateway is network-exposed without TLS
# Adds a TLS check inside the isExposed block of noteSecurityWarnings().
# When gateway is bound to a non-loopback address and TLS is not enabled,
# pushes a WARNING about plaintext credentials/data on the network.
set -euo pipefail
cd "$1"

FILE="src/commands/doctor-security.ts"

# ─── Idempotent check ────────────────────────────────────────────────────────
if grep -q 'without TLS' "$FILE" 2>/dev/null; then
  echo "SKIP: $FILE already patched (TLS warning present)"
  echo "DONE: PR #22112 — nothing to do"
  exit 0
fi

# ─── Patch: Add TLS check inside isExposed block ─────────────────────────────
# In v2026.2.23, the isExposed block ends with:
#     }          ← closes the else (auth configured) branch
#   }            ← closes the if (isExposed) block
#
# We insert the TLS check between these two closing braces.
# The anchor is the else-block's closing "}" followed by the isExposed closing "}".

python3 -c "
import sys

path = '$FILE'
with open(path, 'r') as f:
    content = f.read()

# Find the anchor: the closing of the else block + closing of isExposed
# In context:
#       ...saferRemoteAccessLines,
#     );
#   }
# }                   <-- we insert BEFORE this line
#
# We look for the pattern that uniquely identifies this location:
#   'Ensure your auth credentials' ... saferRemoteAccessLines ... );  }  }

anchor = '''    }
  }

  const warnDmPolicy'''

if anchor not in content:
    print('ERROR: Could not find anchor block in ' + path, file=sys.stderr)
    sys.exit(1)

replacement = '''    }

    const tlsEnabled = cfg.gateway?.tls?.enabled === true;
    if (!tlsEnabled) {
      warnings.push(
        \x60- WARNING: Gateway bound to \${bindDescriptor} without TLS.\x60,
        \x60  Credentials and chat data are sent in plaintext on the network.\x60,
        \x60  Fix: Enable TLS (\${formatCliCommand(\"openclaw config set gateway.tls.enabled true\")})\x60,
        \x60  or use loopback binding (\${formatCliCommand(\"openclaw config set gateway.bind loopback\")}).\x60,
      );
    }
  }

  const warnDmPolicy'''

content = content.replace(anchor, replacement, 1)
with open(path, 'w') as f:
    f.write(content)
print('OK: Patched ' + path + ' — added TLS warning in isExposed block')
"

echo "DONE: PR #22112 applied successfully"
