#!/usr/bin/env bash
set -euo pipefail
cd "$1"

# PR #11160 - fix: add missing audio MIME-to-extension mappings (aac, flac, opus, wav)
# Changes: In src/media/mime.ts, add 4 missing audio MIME entries to EXT_BY_MIME:
#   "audio/aac": ".aac"
#   "audio/flac": ".flac"
#   "audio/opus": ".opus"
#   "audio/wav": ".wav"

TARGET="src/media/mime.ts"

if [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET not found"
  exit 1
fi

# Idempotency: check if all 4 entries already exist
MISSING=0
for MIME in "audio/aac" "audio/flac" "audio/opus" "audio/wav"; do
  if ! grep -q "\"$MIME\"" "$TARGET"; then
    MISSING=1
    break
  fi
done

if [ "$MISSING" -eq 0 ]; then
  echo "SKIP: All audio MIME mappings already present in $TARGET"
  exit 0
fi

# Verify the EXT_BY_MIME object exists
if ! grep -q 'EXT_BY_MIME' "$TARGET"; then
  echo "FAIL: EXT_BY_MIME not found in $TARGET"
  exit 1
fi

python3 << 'PYEOF'
import sys

target = "src/media/mime.ts"
with open(target, "r") as f:
    lines = f.readlines()

# Strategy: find existing audio entries in EXT_BY_MIME and insert new ones nearby
# We need to add aac and flac BEFORE the first audio entry,
# and opus and wav AFTER audio/mpeg (or before audio/x-m4a)

new_entries = {
    "audio/aac": '  "audio/aac": ".aac",\n',
    "audio/flac": '  "audio/flac": ".flac",\n',
    "audio/opus": '  "audio/opus": ".opus",\n',
    "audio/wav": '  "audio/wav": ".wav",\n',
}

# Check which entries are already present
existing = set()
for line in lines:
    for mime in new_entries:
        if f'"{mime}"' in line:
            existing.add(mime)

to_add_before_audio = []  # aac, flac -> before first audio/ entry
to_add_after_mpeg = []     # opus, wav -> after audio/mpeg entry

if "audio/aac" not in existing:
    to_add_before_audio.append(new_entries["audio/aac"])
if "audio/flac" not in existing:
    to_add_before_audio.append(new_entries["audio/flac"])
if "audio/opus" not in existing:
    to_add_after_mpeg.append(new_entries["audio/opus"])
if "audio/wav" not in existing:
    to_add_after_mpeg.append(new_entries["audio/wav"])

# Find the first "audio/" line in EXT_BY_MIME
# We're inside the EXT_BY_MIME object (between the opening { and closing })
in_ext_by_mime = False
first_audio_idx = None
mpeg_idx = None
result = []

for i, line in enumerate(lines):
    if 'EXT_BY_MIME' in line and '{' in line:
        in_ext_by_mime = True
    if in_ext_by_mime:
        if '"audio/' in line and first_audio_idx is None:
            first_audio_idx = len(result)
        if '"audio/mpeg"' in line:
            mpeg_idx = len(result)
        if line.strip() == '};':
            in_ext_by_mime = False
    result.append(line)

if first_audio_idx is None:
    print("FAIL: No audio/ entries found in EXT_BY_MIME", file=sys.stderr)
    sys.exit(1)

# Insert aac and flac before first audio entry
if to_add_before_audio:
    for j, entry in enumerate(to_add_before_audio):
        result.insert(first_audio_idx + j, entry)
    # Adjust mpeg_idx since we inserted lines before it
    if mpeg_idx is not None:
        mpeg_idx += len(to_add_before_audio)

# Insert opus and wav after audio/mpeg
if to_add_after_mpeg and mpeg_idx is not None:
    for j, entry in enumerate(to_add_after_mpeg):
        result.insert(mpeg_idx + 1 + j, entry)
elif to_add_after_mpeg:
    # Fallback: insert before audio/x-m4a if mpeg not found
    for i, line in enumerate(result):
        if '"audio/x-m4a"' in line:
            for j, entry in enumerate(to_add_after_mpeg):
                result.insert(i + j, entry)
            break
    else:
        print("FAIL: Could not find insertion point for opus/wav", file=sys.stderr)
        sys.exit(1)

with open(target, "w") as f:
    f.writelines(result)

added = []
if "audio/aac" not in existing:
    added.append("audio/aac")
if "audio/flac" not in existing:
    added.append("audio/flac")
if "audio/opus" not in existing:
    added.append("audio/opus")
if "audio/wav" not in existing:
    added.append("audio/wav")
print(f"OK: Added MIME mappings: {', '.join(added)}")
PYEOF

# Verify all 4 entries exist
VERIFY_OK=1
for MIME in "audio/aac" "audio/flac" "audio/opus" "audio/wav"; do
  if ! grep -q "\"$MIME\"" "$TARGET"; then
    echo "FAIL: $MIME not found after patching"
    VERIFY_OK=0
  fi
done

if [ "$VERIFY_OK" -eq 1 ]; then
  echo "OK: PR #11160 applied successfully - all 4 audio MIME mappings present"
else
  exit 1
fi
