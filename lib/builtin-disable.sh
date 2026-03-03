#!/usr/bin/env bash
# lib/builtin-disable.sh — Auto-disable built-in extensions that conflict with custom ones
# Source: lib/common.sh must be loaded first
#
# Usage:
#   source lib/common.sh
#   source lib/builtin-disable.sh
#   disable_builtin_extensions

disable_builtin_extensions() {
  step "Disabling conflicting built-in extensions"

  local ext_dir="$OPENCLAW_EXTENSIONS_BUILTIN"

  if [ ! -d "$ext_dir" ]; then
    warn "Built-in extensions directory not found: $ext_dir"
    return 0
  fi

  # Read from extensions.yaml
  local builtins
  builtins=$(yq -o=json '.' "$EXTENSIONS_YAML" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for b in data.get('disabled_builtins', []):
    print(b['name'])
" 2>/dev/null)

  if [ -z "$builtins" ]; then
    info "No built-in extensions to disable"
    return 0
  fi

  local count=0
  local failed=0

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    local src="$ext_dir/$name"
    local dst="$ext_dir/$name.disabled"

    if [ -d "$dst" ] && [ ! -d "$src" ]; then
      ok "Already disabled: $name"
      count=$((count + 1))
      continue
    fi

    if [ -d "$src" ]; then
      info "Disabling built-in: $name"
      if sudo mv "$src" "$dst" 2>/dev/null; then
        ok "Disabled: $name -> $name.disabled"
        count=$((count + 1))
      else
        fail "Failed to disable: $name (sudo required)"
        failed=$((failed + 1))
      fi
    else
      info "Built-in not found: $name (may not exist in this version)"
    fi
  done <<< "$builtins"

  if [ $failed -gt 0 ]; then
    fail "$failed built-in extension(s) could not be disabled"
    return 1
  fi

  ok "$count built-in extension(s) handled"
}

# Verify that built-in extensions are properly disabled
verify_builtin_disabled() {
  step "Verifying built-in extensions are disabled"

  local ext_dir="$OPENCLAW_EXTENSIONS_BUILTIN"
  local all_ok=true

  local builtins
  builtins=$(yq -o=json '.' "$EXTENSIONS_YAML" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for b in data.get('disabled_builtins', []):
    print(b['name'])
" 2>/dev/null)

  while IFS= read -r name; do
    [ -z "$name" ] && continue

    if [ -d "$ext_dir/$name" ] && [ ! -d "$ext_dir/$name.disabled" ]; then
      fail "Built-in NOT disabled: $name — will conflict with custom extension"
      all_ok=false
    elif [ -d "$ext_dir/$name.disabled" ]; then
      ok "Disabled: $name"
    else
      info "Not present: $name"
    fi
  done <<< "$builtins"

  $all_ok
}
