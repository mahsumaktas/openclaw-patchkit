#!/usr/bin/env bash
# PR #20867 - fix: allow video and audio in models.input config
# Bedrock discovery only mapped text and image modalities.
# This adds video and audio support to mapInputModalities,
# ModelDefinitionConfig type, and the Zod schema.
set -euo pipefail
cd "$1"

# 1. Update bedrock-discovery.ts - expand type and add video/audio cases
python3 -c "
with open('src/agents/bedrock-discovery.ts', 'r') as f:
    content = f.read()

old = '''function mapInputModalities(summary: BedrockModelSummary): Array<\"text\" | \"image\"> {
  const inputs = summary.inputModalities ?? [];
  const mapped = new Set<\"text\" | \"image\">();'''
new = '''function mapInputModalities(
  summary: BedrockModelSummary,
): Array<\"text\" | \"image\" | \"video\" | \"audio\"> {
  const inputs = summary.inputModalities ?? [];
  const mapped = new Set<\"text\" | \"image\" | \"video\" | \"audio\">();'''
content = content.replace(old, new, 1)

old2 = '''    if (lower === \"image\") {
      mapped.add(\"image\");
    }
  }'''
new2 = '''    if (lower === \"image\") {
      mapped.add(\"image\");
    }
    if (lower === \"video\") {
      mapped.add(\"video\");
    }
    if (lower === \"audio\") {
      mapped.add(\"audio\");
    }
  }'''
content = content.replace(old2, new2, 1)

with open('src/agents/bedrock-discovery.ts', 'w') as f:
    f.write(content)
print('Updated bedrock-discovery.ts')
"

# 2. Update types.models.ts - expand input type
sed -i.bak 's|input: Array<"text" | "image">;|input: Array<"text" | "image" | "video" | "audio">;|' \
  src/config/types.models.ts

# 3. Update zod-schema.core.ts - expand Zod union
python3 -c "
with open('src/config/zod-schema.core.ts', 'r') as f:
    content = f.read()

old = 'z.array(z.union([z.literal(\"text\"), z.literal(\"image\")]))'  
new = 'z.array(\n        z.union([z.literal(\"text\"), z.literal(\"image\"), z.literal(\"video\"), z.literal(\"audio\")]),\n      )'
if old in content:
    content = content.replace(old, new, 1)
    with open('src/config/zod-schema.core.ts', 'w') as f:
        f.write(content)
    print('Updated zod-schema.core.ts')
else:
    print('SKIP: Zod schema already updated or pattern differs')
"

rm -f src/config/types.models.ts.bak
echo "Applied PR #20867 - video/audio in models.input"
