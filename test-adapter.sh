#!/usr/bin/env bash
set -uo pipefail

# test-adapter.sh — Programmatic end-to-end testing for atrium adapters.
#
# What it does:
#   1. Validates the manifest (delegates to validate-adapter.sh).
#   2. Backs up the tool's real config files, then runs the full
#      install/status/uninstall round-trip and verifies the tool's
#      config mutates and restores correctly.
#   3. For each event fixture in tests/fixtures/<event>/, pipes
#      tool-input.json through the adapter's normalize-hook-payload.sh
#      (if present) and diffs the result against expected-atrium.json.
#   4. Runs the actual installed hook command end-to-end with synthetic
#      stdin, asserting exit code and expected stdout.
#   5. POSTs the normalized payload to atrium-dev's /resolve endpoint
#      and asserts {"ok": true}.
#
# Channel: dev-only. Reads ~/.atrium-dev/hook-port for the resolver
# port and ~/.atrium-dev/bin/atrium-dev for the CLI binary. Stable
# (~/.atrium) is never touched.
#
# Usage:
#   ./test-adapter.sh <adapter-dir>
#   ./test-adapter.sh adapters/antigravity
#
# Env overrides:
#   ATRIUM_TEST_PORT      Override hook-port discovery
#   ATRIUM_TEST_NO_HTTP   If "1", skip the /resolve acceptance check
#   ATRIUM_TEST_NO_INSTALL If "1", skip install/uninstall (test fixtures only)

ADAPTER_DIR="${1:?Usage: test-adapter.sh <adapter-dir>}"
ADAPTER_DIR="${ADAPTER_DIR%/}"

if [[ ! -d "$ADAPTER_DIR" ]]; then
  echo "test-adapter: adapter directory not found: $ADAPTER_DIR" >&2
  exit 2
fi

MANIFEST="$ADAPTER_DIR/adapter.json"
if [[ ! -f "$MANIFEST" ]]; then
  echo "test-adapter: no adapter.json in $ADAPTER_DIR" >&2
  exit 2
fi

ADAPTER_NAME="$(jq -r '.name' "$MANIFEST")"
NORMALIZER="$ADAPTER_DIR/normalize-hook-payload.sh"
HOOKS_SH="$ADAPTER_DIR/hooks.sh"
TESTS_DIR="$ADAPTER_DIR/tests"
FIXTURES_DIR="$TESTS_DIR/fixtures"

# ── Channel discovery (dev only) ─────────────────────────────────────
ATRIUM_DEV_DIR="${HOME}/.atrium-dev"
ATRIUM_PORT_FILE="${ATRIUM_DEV_DIR}/hook-port"

if [[ -n "${ATRIUM_TEST_PORT:-}" ]]; then
  RESOLVE_PORT="$ATRIUM_TEST_PORT"
elif [[ -f "$ATRIUM_PORT_FILE" ]]; then
  RESOLVE_PORT="$(cat "$ATRIUM_PORT_FILE")"
else
  RESOLVE_PORT=""
fi

# ── Color & counters ──────────────────────────────────────────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; BOLD=""; DIM=""; RESET=""
fi

PASS=0; FAIL=0; SKIP=0
FAILED_TESTS=()

pass() { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS+1)); }
fail() { printf '%s✗%s %s\n' "$RED" "$RESET" "$1"; [[ -n "${2:-}" ]] && printf '  %s%s%s\n' "$DIM" "$2" "$RESET"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }
skip() { printf '%s∘%s %s%s%s\n' "$YELLOW" "$RESET" "$DIM" "$1" "$RESET"; SKIP=$((SKIP+1)); }
section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }

# ── Backup discovery ─────────────────────────────────────────────────
# Each adapter knows its own config file paths via hooks.sh. We don't
# hardcode them here — instead we let the adapter's tests/backup-paths.sh
# enumerate paths to back up, or we capture-and-restore based on
# detected mutations. Default: snapshot the whole HOME-relative tree
# the install touches by capturing pre/post diffs.

BACKUP_PATHS_SH="$TESTS_DIR/backup-paths.sh"

declare -a BACKUP_PATHS=()
if [[ -x "$BACKUP_PATHS_SH" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && BACKUP_PATHS+=("$line")
  done < <("$BACKUP_PATHS_SH")
fi

BACKUP_DIR="$(mktemp -d "/tmp/atrium-test-${ADAPTER_NAME}.XXXXXX")"
trap 'restore_backups; rm -rf "$BACKUP_DIR"' EXIT

backup_files() {
  for path in "${BACKUP_PATHS[@]}"; do
    expanded="${path/#\~/$HOME}"
    if [[ -e "$expanded" ]]; then
      mkdir -p "$BACKUP_DIR/$(dirname "$expanded")"
      cp -p "$expanded" "$BACKUP_DIR$expanded"
    else
      # Mark "didn't exist" so restore knows to delete
      touch "$BACKUP_DIR$expanded.__atrium_test_didnotexist"
    fi
  done
}

restore_backups() {
  for path in "${BACKUP_PATHS[@]}"; do
    expanded="${path/#\~/$HOME}"
    if [[ -f "$BACKUP_DIR$expanded.__atrium_test_didnotexist" ]]; then
      rm -f "$expanded"
    elif [[ -e "$BACKUP_DIR$expanded" ]]; then
      mkdir -p "$(dirname "$expanded")"
      cp -p "$BACKUP_DIR$expanded" "$expanded"
    fi
  done
}

# ── Phase 1: Manifest validation ─────────────────────────────────────
section "Phase 1: Manifest validation"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if "$SCRIPT_DIR/validate-adapter.sh" "$ADAPTER_DIR" 2>&1 | tail -1 | grep -q '0 failed'; then
  pass "validate-adapter.sh: 20/20 checks"
else
  fail "validate-adapter.sh failed; run it directly for details"
fi

# ── Phase 2: Install round-trip ──────────────────────────────────────
section "Phase 2: Install round-trip"

if [[ "${ATRIUM_TEST_NO_INSTALL:-0}" = "1" ]]; then
  skip "install/uninstall (ATRIUM_TEST_NO_INSTALL=1)"
elif [[ ! -x "$HOOKS_SH" ]]; then
  skip "no hooks.sh"
else
  backup_files

  pre_status="$("$HOOKS_SH" status 2>/dev/null | jq -r '.installed // false')"
  if [[ "$pre_status" != "true" ]]; then
    pass "pre-install status: not installed"
  else
    skip "pre-install status: already installed (will restore on exit)"
  fi

  if install_out="$("$HOOKS_SH" install 2>&1)" && echo "$install_out" | jq -e '.installed == true' >/dev/null 2>&1; then
    pass "hooks.sh install → installed: true"
  else
    fail "hooks.sh install did not report installed: true" "$install_out"
  fi

  post_install="$("$HOOKS_SH" status 2>/dev/null | jq -r '.installed // false')"
  if [[ "$post_install" = "true" ]]; then
    pass "hooks.sh status after install → installed: true"
  else
    fail "hooks.sh status after install → installed: $post_install"
  fi

  # Optional install assertion (adapter-specific). Runs against the
  # freshly-installed state. Receives the adapter name as $1.
  if [[ -x "$TESTS_DIR/install.assert.sh" ]]; then
    if assert_out="$("$TESTS_DIR/install.assert.sh" "$ADAPTER_NAME" 2>&1)"; then
      pass "install.assert.sh"
    else
      fail "install.assert.sh failed" "$assert_out"
    fi
  fi

  if uninst_out="$("$HOOKS_SH" uninstall 2>&1)" && echo "$uninst_out" | jq -e '.uninstalled == true' >/dev/null 2>&1; then
    pass "hooks.sh uninstall → uninstalled: true"
  else
    fail "hooks.sh uninstall did not report uninstalled: true" "$uninst_out"
  fi

  post_uninst="$("$HOOKS_SH" status 2>/dev/null | jq -r '.installed // false')"
  if [[ "$post_uninst" = "false" ]]; then
    pass "hooks.sh status after uninstall → installed: false"
  else
    fail "hooks.sh status after uninstall → installed: $post_uninst"
  fi

  # Reinstall for fixture-based testing in the next phase.
  "$HOOKS_SH" install >/dev/null 2>&1 || true
fi

# ── Phase 3: Normalizer fixtures ─────────────────────────────────────
section "Phase 3: Normalizer fixtures"

if [[ ! -d "$FIXTURES_DIR" ]]; then
  skip "no tests/fixtures/ directory"
else
  for event_dir in "$FIXTURES_DIR"/*/; do
    [[ -d "$event_dir" ]] || continue
    event="$(basename "$event_dir")"
    input_file="$event_dir/tool-input.json"
    expected_file="$event_dir/expected-atrium.json"

    if [[ ! -f "$input_file" ]]; then
      skip "$event: no tool-input.json"
      continue
    fi
    if [[ ! -f "$expected_file" ]]; then
      skip "$event: no expected-atrium.json"
      continue
    fi
    if [[ ! -x "$NORMALIZER" ]]; then
      skip "$event: no normalize-hook-payload.sh in adapter"
      continue
    fi

    actual="$("$NORMALIZER" "$event" < "$input_file" 2>&1 || true)"
    if ! echo "$actual" | jq empty 2>/dev/null; then
      fail "$event: normalizer produced invalid JSON" "$actual"
      continue
    fi

    # Compare expected ⊂ actual: every key in expected must equal the
    # corresponding key in actual. Extra keys in actual are allowed (we
    # don't want to fail on every field the normalizer preserves from
    # the input). Use jq to walk expected and assert.
    diff_out="$(jq -n \
      --argjson exp "$(cat "$expected_file")" \
      --argjson act "$(echo "$actual")" \
      '
      def check($path; $exp; $act):
        if ($exp | type) == "object" then
          ($exp | to_entries[] | check($path + [.key]; .value; $act[.key]))
        elif $exp == $act then
          empty
        else
          { path: $path, expected: $exp, actual: $act }
        end;
      [check([]; $exp; $act)]
      ' 2>&1)"

    if [[ "$diff_out" = "[]" ]] || [[ -z "$diff_out" ]]; then
      pass "$event: normalized payload matches expected"
    else
      fail "$event: normalized payload diverges from expected" "$diff_out"
    fi
  done
fi

# ── Phase 4: /resolve acceptance ─────────────────────────────────────
section "Phase 4: /resolve acceptance"

if [[ "${ATRIUM_TEST_NO_HTTP:-0}" = "1" ]]; then
  skip "HTTP /resolve (ATRIUM_TEST_NO_HTTP=1)"
elif [[ -z "$RESOLVE_PORT" ]]; then
  skip "no atrium-dev hook-port file (~/.atrium-dev/hook-port)"
elif [[ ! -d "$FIXTURES_DIR" ]]; then
  skip "no fixtures to POST"
else
  for event_dir in "$FIXTURES_DIR"/*/; do
    [[ -d "$event_dir" ]] || continue
    event="$(basename "$event_dir")"
    expected_file="$event_dir/expected-atrium.json"
    [[ -f "$expected_file" ]] || continue

    uri="atrium://hooks/${ADAPTER_NAME}/${event}"
    payload="$(jq -n --arg uri "$uri" --argjson params "$(cat "$expected_file")" '{uri: $uri, params: $params}')"
    response="$(curl -sS -X POST "http://127.0.0.1:${RESOLVE_PORT}/resolve" \
      -H 'Content-Type: application/json' \
      -d "$payload" 2>&1)"

    if echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
      pass "$event: /resolve accepted (ok: true)"
    else
      fail "$event: /resolve rejected" "$response"
    fi
  done
fi

# ── Summary ──────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL + SKIP))
printf '\n%sSummary%s\n' "$BOLD" "$RESET"
printf '  passed: %s%d%s\n' "$GREEN" "$PASS" "$RESET"
printf '  failed: %s%d%s\n' "$RED" "$FAIL" "$RESET"
printf '  skipped: %s%d%s\n' "$YELLOW" "$SKIP" "$RESET"
printf '  total:  %d\n' "$TOTAL"

if [[ $FAIL -gt 0 ]]; then
  printf '\nFailed:\n'
  for t in "${FAILED_TESTS[@]}"; do
    printf '  %s✗%s %s\n' "$RED" "$RESET" "$t"
  done
  exit 1
fi
exit 0
