#!/usr/bin/env bash
set -euo pipefail

# validate-adapter -- Validates an atrium adapter's structure and outputs.
# Usage: validate-adapter <adapter-directory>
# Exit codes: 0 = all pass, 1 = failures, 2 = usage error

VERSION="1.0.0"

# ── Color support ──────────────────────────────────────────────────────────────

NO_COLOR="${NO_COLOR:-}"
if [[ "${1:-}" == "--no-color" ]]; then
  NO_COLOR=1
  shift
fi

if [[ -n "$NO_COLOR" ]] || [[ ! -t 1 ]]; then
  GREEN=""
  RED=""
  YELLOW=""
  BOLD=""
  RESET=""
  CHECKMARK="[PASS]"
  CROSS="[FAIL]"
else
  GREEN=$'\033[0;32m'
  RED=$'\033[0;31m'
  YELLOW=$'\033[0;33m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
  CHECKMARK="${GREEN}\xe2\x9c\x93${RESET}"
  CROSS="${RED}\xe2\x9c\x97${RESET}"
fi

# ── Usage ──────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
validate-adapter v${VERSION} -- atrium adapter validation tool

Usage:
  validate-adapter [--no-color] <adapter-directory>
  validate-adapter --help

Options:
  --no-color   Disable colored output (also honors NO_COLOR env var)
  --help       Show this help message

Examples:
  validate-adapter ~/.atrium/adapters/my-tool/
  validate-adapter ./src-tauri/adapters/claude-code/
EOF
  exit 2
}

if [[ $# -lt 1 ]] || [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
  usage
fi

# ── Resolve paths ──────────────────────────────────────────────────────────────

ADAPTER_DIR="${1%/}"

if [[ ! -d "$ADAPTER_DIR" ]]; then
  echo "${CROSS} Adapter directory not found: $ADAPTER_DIR" >&2
  exit 1
fi

# Resolve schema location: env var > ~/.atrium/sdk/schemas/ > script-relative
if [[ -n "${atrium_SDK_SCHEMAS:-}" ]] && [[ -d "$atrium_SDK_SCHEMAS" ]]; then
  SCHEMAS_DIR="$atrium_SDK_SCHEMAS"
else
  # Try relative to this script first (for bundled SDK)
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -d "$SCRIPT_DIR/schemas" ]]; then
    SCHEMAS_DIR="$SCRIPT_DIR/schemas"
  elif [[ -d "$HOME/.atrium/sdk/schemas" ]]; then
    SCHEMAS_DIR="$HOME/.atrium/sdk/schemas"
  else
    echo "${CROSS} Cannot find SDK schemas directory." >&2
    echo "  Set atrium_SDK_SCHEMAS or ensure ~/.atrium/sdk/schemas/ exists." >&2
    exit 1
  fi
fi

# ── Counters ───────────────────────────────────────────────────────────────────

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  printf '%b %s\n' "$CHECKMARK" "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf '%b %s\n' "$CROSS" "$1"
  if [[ -n "${2:-}" ]]; then
    echo "  Expected: $2"
  fi
  if [[ -n "${3:-}" ]]; then
    echo "  Got: $3"
  fi
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

# ── Dependency check ───────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  echo "${CROSS} jq is required but not installed." >&2
  exit 1
fi

# ── Phase 1: Manifest validation ──────────────────────────────────────────────

MANIFEST="$ADAPTER_DIR/adapter.json"

validate_manifest() {
  if [[ ! -f "$MANIFEST" ]]; then
    fail "adapter.json: file not found"
    return
  fi

  # Check valid JSON
  if ! jq empty "$MANIFEST" 2>/dev/null; then
    fail "adapter.json: invalid JSON"
    return
  fi

  pass "adapter.json: valid JSON"

  # Check required fields
  local required_fields=("sdkVersion" "name" "displayName" "description" "accent" "binary" "version" "methods")
  local missing=()
  for field in "${required_fields[@]}"; do
    if [[ "$(jq --arg f "$field" 'has($f)' "$MANIFEST")" != "true" ]]; then
      missing+=("$field")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    fail "adapter.json: missing required fields: ${missing[*]}"
    return
  fi

  pass "adapter.json: all required fields present"

  # Validate sdkVersion. SDK v2 is the current shape used by every adapter
  # in the registry (lean method set, binaryDiscovery + skillInstallPath on
  # the manifest). v1 is still accepted for older community adapters.
  local sdk_version
  sdk_version=$(jq -r '.sdkVersion' "$MANIFEST")
  if [[ "$sdk_version" != "1" ]] && [[ "$sdk_version" != "2" ]]; then
    fail "adapter.json: unsupported sdkVersion" "1 or 2" "$sdk_version"
  else
    pass "adapter.json: sdkVersion is $sdk_version"
  fi

  # Validate name pattern
  local name
  name=$(jq -r '.name' "$MANIFEST")
  if [[ ! "$name" =~ ^[a-z0-9-]+$ ]]; then
    fail "adapter.json: name must match ^[a-z0-9-]+\$" "lowercase alphanumeric with hyphens" "$name"
  else
    pass "adapter.json: name '$name' is valid"
  fi

  # Validate accent pattern
  local accent
  accent=$(jq -r '.accent' "$MANIFEST")
  if [[ ! "$accent" =~ ^#[0-9a-fA-F]{6}$ ]]; then
    fail "adapter.json: accent must be a hex color (#RRGGBB)" "^#[0-9a-fA-F]{6}\$" "$accent"
  else
    pass "adapter.json: accent '$accent' is valid"
  fi

  # Validate version pattern
  local version
  version=$(jq -r '.version' "$MANIFEST")
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    fail "adapter.json: version must be semver" "^[0-9]+.[0-9]+.[0-9]+" "$version"
  else
    pass "adapter.json: version '$version' is valid"
  fi
}

# ── Phase 2: Script existence and permission checks ───────────────────────────

validate_scripts_exist() {
  local methods
  methods=$(jq -r '.methods // {} | keys[]' "$MANIFEST" 2>/dev/null) || return

  for method in $methods; do
    # Check if it's a script method
    local script
    script=$(jq -r --arg m "$method" '.methods[$m].script // empty' "$MANIFEST")
    if [[ -n "$script" ]]; then
      local script_path="$ADAPTER_DIR/$script"
      if [[ ! -f "$script_path" ]]; then
        fail "$script: file not found"
        continue
      fi
      if [[ ! -x "$script_path" ]]; then
        fail "$script: not executable (chmod +x needed)"
        continue
      fi
      pass "$script: exists, executable"
      continue
    fi

    # Check if it's a static method
    local static_file
    static_file=$(jq -r --arg m "$method" '.methods[$m].static // empty' "$MANIFEST")
    if [[ -n "$static_file" ]]; then
      local static_path="$ADAPTER_DIR/$static_file"
      if [[ ! -f "$static_path" ]]; then
        fail "$static_file: file not found"
        continue
      fi
      if ! jq empty "$static_path" 2>/dev/null; then
        fail "$static_file: not valid JSON"
        continue
      fi
      pass "$static_file: exists, valid JSON"
    fi
  done
}

# ── Phase 3: Schema validation helpers ────────────────────────────────────────

# Get the JSON type of a value (string, number, boolean, null, array, object)
jq_type() {
  echo "$1" | jq -r 'type' 2>/dev/null || echo "invalid"
}

# Validate a JSON value against a property schema definition.
# Returns 0 if valid, 1 if invalid. Sets VALIDATE_ERROR on failure.
VALIDATE_ERROR=""

validate_type() {
  local json_value="$1"
  local prop_schema="$2"
  local prop_name="$3"

  local actual_type
  actual_type=$(jq_type "$json_value")

  # Check for oneOf pattern
  local has_oneof
  has_oneof=$(echo "$prop_schema" | jq 'has("oneOf")' 2>/dev/null)
  if [[ "$has_oneof" == "true" ]]; then
    local allowed_types
    allowed_types=$(echo "$prop_schema" | jq -r '.oneOf[].type' 2>/dev/null)
    for allowed in $allowed_types; do
      if [[ "$actual_type" == "$allowed" ]]; then
        return 0
      fi
    done
    VALIDATE_ERROR="$prop_name: expected one of [$allowed_types], got $actual_type"
    return 1
  fi

  # Check direct type
  local expected_type
  expected_type=$(echo "$prop_schema" | jq -r '.type // empty' 2>/dev/null)
  if [[ -n "$expected_type" ]]; then
    if [[ "$actual_type" != "$expected_type" ]]; then
      VALIDATE_ERROR="$prop_name: expected type '$expected_type', got '$actual_type'"
      return 1
    fi

    # For arrays, check minItems if specified
    if [[ "$expected_type" == "array" ]]; then
      local min_items
      min_items=$(echo "$prop_schema" | jq -r '.minItems // empty' 2>/dev/null)
      if [[ -n "$min_items" ]]; then
        local actual_len
        actual_len=$(echo "$json_value" | jq 'length' 2>/dev/null)
        if [[ "$actual_len" -lt "$min_items" ]]; then
          VALIDATE_ERROR="$prop_name: array needs at least $min_items item(s), got $actual_len"
          return 1
        fi
      fi

      # Check array item types if items.type is specified
      local item_type
      item_type=$(echo "$prop_schema" | jq -r '.items.type // empty' 2>/dev/null)
      if [[ -n "$item_type" ]]; then
        local bad_indices
        bad_indices=$(echo "$json_value" | jq -r --arg t "$item_type" '[to_entries[] | select((.value | type) != $t) | .key] | join(", ")' 2>/dev/null)
        if [[ -n "$bad_indices" ]]; then
          VALIDATE_ERROR="$prop_name: array items at index [$bad_indices] are not of type '$item_type'"
          return 1
        fi
      fi
    fi
  fi

  return 0
}

# Validate a JSON output against a method schema file.
# For hooks, we only validate the "status" variant of the oneOf.
validate_output_against_schema() {
  local output="$1"
  local schema_file="$2"
  local method_name="$3"

  if [[ ! -f "$schema_file" ]]; then
    fail "$method_name: schema file not found at $schema_file"
    return
  fi

  local schema
  schema=$(cat "$schema_file")

  # Determine the effective schema to validate against.
  # For hooks, the top-level is oneOf -- pick the status variant.
  local effective_schema
  local has_top_oneof
  has_top_oneof=$(echo "$schema" | jq 'has("oneOf")' 2>/dev/null)
  if [[ "$has_top_oneof" == "true" ]]; then
    # For hooks: pick the oneOf entry that has required: ["installed", "subcommand"]
    # and properties.subcommand.const == "status"
    effective_schema=$(echo "$schema" | jq '.oneOf[] | select(.properties.subcommand.const == "status")' 2>/dev/null)
    if [[ -z "$effective_schema" ]]; then
      # Fallback: use first oneOf entry
      effective_schema=$(echo "$schema" | jq '.oneOf[0]' 2>/dev/null)
    fi
  else
    effective_schema="$schema"
  fi

  # Check required keys
  local required_keys
  required_keys=$(echo "$effective_schema" | jq -r '.required[]' 2>/dev/null) || true

  for key in $required_keys; do
    local has_key
    has_key=$(echo "$output" | jq --arg k "$key" 'has($k)' 2>/dev/null)
    if [[ "$has_key" != "true" ]]; then
      local expected_output
      expected_output=$(echo "$effective_schema" | jq -r '.required | join(", ")' 2>/dev/null)
      local actual_keys
      actual_keys=$(echo "$output" | jq -r 'keys | join(", ")' 2>/dev/null)
      fail "$method_name: output missing required key \"$key\"" "keys: [$expected_output]" "keys: [$actual_keys]"
      return
    fi
  done

  # Validate types for each required key
  local properties
  properties=$(echo "$effective_schema" | jq '.properties // {}' 2>/dev/null)

  for key in $required_keys; do
    local prop_schema
    prop_schema=$(echo "$properties" | jq --arg k "$key" '.[$k] // {}' 2>/dev/null)
    local value
    value=$(echo "$output" | jq --arg k "$key" '.[$k]' 2>/dev/null)

    if ! validate_type "$value" "$prop_schema" "$key"; then
      fail "$method_name: $VALIDATE_ERROR"
      return
    fi
  done

  # Validate types for optional keys that are present
  local all_prop_keys
  all_prop_keys=$(echo "$properties" | jq -r 'keys[]' 2>/dev/null) || true
  for key in $all_prop_keys; do
    local has_key
    has_key=$(echo "$output" | jq --arg k "$key" 'has($k)' 2>/dev/null)
    if [[ "$has_key" == "true" ]]; then
      local prop_schema
      prop_schema=$(echo "$properties" | jq --arg k "$key" '.[$k] // {}' 2>/dev/null)
      local value
      value=$(echo "$output" | jq --arg k "$key" '.[$k]' 2>/dev/null)

      if ! validate_type "$value" "$prop_schema" "$key"; then
        fail "$method_name: $VALIDATE_ERROR"
        return
      fi
    fi
  done

  # For list_recent_sessions, validate nested array objects
  if [[ "$method_name" == "list_recent_sessions" ]]; then
    local items_schema
    items_schema=$(echo "$effective_schema" | jq '.properties.sessions.items // empty' 2>/dev/null)
    if [[ -n "$items_schema" ]]; then
      local session_count
      session_count=$(echo "$output" | jq '.sessions | length' 2>/dev/null)
      local item_required
      item_required=$(echo "$items_schema" | jq -r '.required[]' 2>/dev/null) || true

      local i=0
      while [[ $i -lt ${session_count:-0} ]]; do
        for rkey in $item_required; do
          local has_item_key
          has_item_key=$(echo "$output" | jq --argjson idx "$i" --arg k "$rkey" '.sessions[$idx] | has($k)' 2>/dev/null)
          if [[ "$has_item_key" != "true" ]]; then
            fail "$method_name: sessions[$i] missing required key \"$rkey\""
            return
          fi
        done
        i=$((i + 1))
      done
    fi
  fi

  # For launcher_options, validate nested array objects
  if [[ "$method_name" == "launcher_options" ]]; then
    local items_schema
    items_schema=$(echo "$effective_schema" | jq '.properties.options.items // empty' 2>/dev/null)
    if [[ -n "$items_schema" ]]; then
      local option_count
      option_count=$(echo "$output" | jq '.options | length' 2>/dev/null)
      local item_required
      item_required=$(echo "$items_schema" | jq -r '.required[]' 2>/dev/null) || true

      local i=0
      while [[ $i -lt ${option_count:-0} ]]; do
        for rkey in $item_required; do
          local has_item_key
          has_item_key=$(echo "$output" | jq --argjson idx "$i" --arg k "$rkey" '.options[$idx] | has($k)' 2>/dev/null)
          if [[ "$has_item_key" != "true" ]]; then
            fail "$method_name: options[$i] missing required key \"$rkey\""
            return
          fi
        done
        i=$((i + 1))
      done
    fi
  fi

  pass "$method_name: output matches schema"
}

# ── Phase 3: Dry-run execution and output validation ──────────────────────────

# Returns synthetic invocation arguments for a given method name.
# Compatible with bash 3.x (no associative arrays).
get_method_args() {
  case "$1" in
    detect_binary)          echo "" ;;
    detect_running)         echo "1" ;;
    extract_session_id)     echo "1" ;;
    list_recent_sessions)   echo "/tmp" ;;
    build_launch_command)   echo "{}" ;;
    build_resume_command)   echo "test-session-id {}" ;;
    check_auth)             echo "" ;;
    hooks)                  echo "status" ;;
    *)                      echo "" ;;
  esac
}

validate_outputs() {
  local methods
  methods=$(jq -r '.methods // {} | keys[]' "$MANIFEST" 2>/dev/null) || return

  for method in $methods; do
    local schema_file="$SCHEMAS_DIR/methods/${method}.schema.json"

    # Script method
    local script
    script=$(jq -r --arg m "$method" '.methods[$m].script // empty' "$MANIFEST")
    if [[ -n "$script" ]]; then
      local script_path="$ADAPTER_DIR/$script"
      if [[ ! -x "$script_path" ]]; then
        # Already reported in phase 2, skip dry-run
        continue
      fi

      # Get synthetic args for this method
      local args
      args=$(get_method_args "$method")

      # Run the script with synthetic inputs
      local output
      local exit_code=0
      # shellcheck disable=SC2086
      output=$("$script_path" $args 2>/dev/null) || exit_code=$?

      if [[ $exit_code -ne 0 ]]; then
        fail "$script: exited with code $exit_code"
        continue
      fi

      # Check output is valid JSON
      if ! echo "$output" | jq empty 2>/dev/null; then
        fail "$script: output is not valid JSON" "valid JSON" "$output"
        continue
      fi

      pass "$script: produces valid JSON"

      # Validate against schema
      validate_output_against_schema "$output" "$schema_file" "$method"
      continue
    fi

    # Static method
    local static_file
    static_file=$(jq -r --arg m "$method" '.methods[$m].static // empty' "$MANIFEST")
    if [[ -n "$static_file" ]]; then
      local static_path="$ADAPTER_DIR/$static_file"
      if [[ ! -f "$static_path" ]]; then
        # Already reported in phase 2
        continue
      fi

      local output
      output=$(cat "$static_path" 2>/dev/null) || true

      if ! echo "$output" | jq empty 2>/dev/null; then
        # Already reported in phase 2
        continue
      fi

      # Validate against schema
      validate_output_against_schema "$output" "$schema_file" "$method"
    fi
  done
}

# ── Main ───────────────────────────────────────────────────────────────────────

echo "${BOLD:-}Validating adapter: $ADAPTER_DIR${RESET:-}"
echo ""

echo "${BOLD:-}Phase 1: Manifest validation${RESET:-}"
validate_manifest
echo ""

# Only proceed with further phases if manifest is valid JSON with required fields
if [[ -f "$MANIFEST" ]] && jq empty "$MANIFEST" 2>/dev/null; then
  echo "${BOLD:-}Phase 2: Script and file checks${RESET:-}"
  validate_scripts_exist
  echo ""

  echo "${BOLD:-}Phase 3: Output validation${RESET:-}"
  validate_outputs
  echo ""
fi

# ── Summary ────────────────────────────────────────────────────────────────────

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "${BOLD:-}Result: ${PASS_COUNT}/${TOTAL} checks passed, ${FAIL_COUNT} failed${RESET:-}"

if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 1
fi
exit 0
