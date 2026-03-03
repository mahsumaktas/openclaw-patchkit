#!/usr/bin/env bash
# lib/fix-validate.sh — Validate FIX script patterns against target version
# Source: lib/common.sh must be loaded first
#
# Usage:
#   source lib/common.sh
#   source lib/fix-validate.sh
#   validate_all_fixes [target_dir]

validate_fix() {
  local fix_yaml="$1"
  local target_dir="${2:-$OPENCLAW_ROOT}"

  local fix_id fix_status
  fix_id=$(yq eval '.id' "$fix_yaml")
  fix_status=$(yq eval '.status' "$fix_yaml")

  # Skip retired fixes
  if [ "$fix_status" = "retired" ]; then
    info "$fix_id: RETIRED — skipping"
    echo "retired"
    return 0
  fi

  local result="ready"

  # Parse YAML once, extract all layer data in a single call
  local layers_json
  layers_json=$(yq -o=json '.layers' "$fix_yaml" 2>/dev/null || echo "[]")

  local layer_count
  layer_count=$(echo "$layers_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

  local i=0
  while [ "$i" -lt "$layer_count" ]; do
    # Extract all fields for this layer in one python3 call
    local layer_data
    layer_data=$(echo "$layers_json" | python3 -c "
import json, sys
layers = json.load(sys.stdin)
l = layers[$i]
print(l.get('status', 'active'))
print(l.get('name', 'unknown'))
print(l.get('target_file_pattern', l.get('target_file', '')))
print(l.get('idempotency_marker', ''))
for p in l.get('expected_patterns', []):
    print('PATTERN:' + json.dumps(p))
" 2>/dev/null)

    local layer_status layer_name target_file_pattern idem_marker
    layer_status=$(echo "$layer_data" | sed -n '1p')
    layer_name=$(echo "$layer_data" | sed -n '2p')
    target_file_pattern=$(echo "$layer_data" | sed -n '3p')
    idem_marker=$(echo "$layer_data" | sed -n '4p')

    if [ "$layer_status" = "obsolete" ]; then
      info "$fix_id/$layer_name: obsolete — skipping"
      i=$((i + 1))
      continue
    fi

    if [ -z "$target_file_pattern" ]; then
      i=$((i + 1))
      continue
    fi

    # Resolve target file (support glob)
    local target_file
    # shellcheck disable=SC2086
    target_file=$(ls "$target_dir"/$target_file_pattern 2>/dev/null | head -1)

    if [ -z "$target_file" ]; then
      warn "$fix_id/$layer_name: target file not found: $target_file_pattern"
      result="needs_adaptation"
      i=$((i + 1))
      continue
    fi

    # Check idempotency marker (already applied?)
    if [ -n "$idem_marker" ] && grep -q "$idem_marker" "$target_file" 2>/dev/null; then
      ok "$fix_id/$layer_name: already applied"
      i=$((i + 1))
      continue
    fi

    # Check expected patterns (extracted from layer_data above)
    local patterns_ok=true
    while IFS= read -r pline; do
      [ -z "$pline" ] && continue
      # Lines prefixed with PATTERN: contain JSON pattern objects
      [[ "$pline" == PATTERN:* ]] || continue
      local pjson="${pline#PATTERN:}"

      local pattern required
      pattern=$(echo "$pjson" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['pattern'])" 2>/dev/null)
      required=$(echo "$pjson" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('required', True))" 2>/dev/null)

      if ! grep -q "$pattern" "$target_file" 2>/dev/null; then
        if [ "$required" = "True" ]; then
          warn "$fix_id/$layer_name: MISSING required pattern: $pattern"
          patterns_ok=false
        else
          info "$fix_id/$layer_name: optional pattern not found: $pattern"
        fi
      fi
    done <<< "$layer_data"

    if $patterns_ok; then
      ok "$fix_id/$layer_name: patterns match — ready to apply"
    else
      result="needs_adaptation"
    fi

    i=$((i + 1))
  done

  echo "$result"
}

validate_all_fixes() {
  local target_dir="${1:-$OPENCLAW_ROOT}"

  step "Validating FIX patch patterns"

  local fix_patterns_dir="$PATCHKIT_ROOT/metadata/fix-patterns"
  local all_ready=true
  local ready_count=0
  local adapt_count=0
  local retired_count=0

  for fix_yaml in "$fix_patterns_dir"/*.yaml; do
    [ -f "$fix_yaml" ] || continue

    local result
    result=$(validate_fix "$fix_yaml" "$target_dir" | tail -1)

    case "$result" in
      ready) ready_count=$((ready_count + 1)) ;;
      retired) retired_count=$((retired_count + 1)) ;;
      needs_adaptation)
        adapt_count=$((adapt_count + 1))
        all_ready=false
        ;;
    esac
  done

  echo ""
  info "FIX validation: $ready_count ready, $adapt_count need adaptation, $retired_count retired"

  if $all_ready; then
    ok "All active FIX patches are ready"
    return 0
  else
    warn "$adapt_count FIX patch(es) need adaptation before upgrade"
    return 1
  fi
}
