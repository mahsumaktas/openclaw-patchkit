#!/usr/bin/env bash
set -euo pipefail
cd "$1"

# PR #11160 - fix: add missing audio MIME-to-extension mappings (aac, flac, opus, wav)

TARGET="src/media/mime.ts"

if [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET not found"
  exit 1
fi

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

if ! grep -q 'EXT_BY_MIME' "$TARGET"; then
  echo "FAIL: EXT_BY_MIME not found in $TARGET"
  exit 1
fi

python3 << 'PYEOF'
import sys

target = "src/media/mime.ts"
with open(target, "r") as f:
    lines = f.readlines()

new_entries = {
    "audio/aac": '  "audio/aac": ".aac",\n',
    "audio/flac": '  "audio/flac": ".flac",\n',
    "audio/opus": '  "audio/opus": ".opus",\n',
    "audio/wav": '  "audio/wav": ".wav",\n',
}

existing = set()
for line in lines:
    for mime in new_entries:
        if f'"{ mime}"' in line:
            existing.add(mime)

to_add_before_audio = []
to_add_after_mpeg = []

if "audio/aac" not in existing:
    to_add_before_audio.append(new_entries["audio/aac"])
if "audio/flac" not in existing:
    to_add_before_audio.append(new_entries["audio/flac"])
if "audio/opus" not in existing:
    to_add_after_mpeg.append(new_entries["audio/opus"])
if "audio/wav" not in existing:
    to_add_after_mpeg.append(new_entries["audio/wav"])

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

if to_add_before_audio:
    for j, entry in enumerate(to_add_before_audio):
        result.insert(first_audio_idx + j, entry)
    if mpeg_idx is not None:
        mpeg_idx += len(to_add_before_audio)

if to_add_after_mpeg and mpeg_idx is not None:
    for j, entry in enumerate(to_add_after_mpeg):
        result.insert(mpeg_idx + 1 + j, entry)
elif to_add_after_mpeg:
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
