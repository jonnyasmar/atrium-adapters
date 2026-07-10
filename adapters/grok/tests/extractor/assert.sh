#!/usr/bin/env bash
set -euo pipefail

# assert.sh — Smoke-test the grok extract_session.sh against a synthetic
# chat_history fixture. Verifies depth filtering + canonical-schema
# conformance via jsonschema (line-level skipped if jsonschema absent).

ADAPTER_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION_ID="$(tr -d '[:space:]' < "$FIXTURE_DIR/fixture-session-id.txt")"
SCHEMAS_DIR="$(cd "$ADAPTER_DIR/../../schemas" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "[SKIP] python3 not available; cannot run extractor fixture test" >&2
  exit 0
fi

if [[ -f "$ADAPTER_DIR/extract_session.py" ]]; then
  THIRD_PARTY=$(grep -E "^(from|import) " "$ADAPTER_DIR/extract_session.py" \
    | grep -vE "^(from|import) (argparse|json|os|pathlib|re|sqlite3|sys|datetime|__future__|hashlib|time|urllib)\b" || true)
  if [[ -n "$THIRD_PARTY" ]]; then
    echo "[FAIL] extract_session.py uses third-party imports:" >&2
    echo "$THIRD_PARTY" >&2
    exit 1
  fi
fi

if ! head -1 "$ADAPTER_DIR/extract_session.sh" | grep -q "^#!/usr/bin/env bash$"; then
  echo "[FAIL] missing or wrong shebang in extract_session.sh" >&2
  exit 1
fi
if ! head -3 "$ADAPTER_DIR/extract_session.sh" | grep -q "^set -euo pipefail$"; then
  echo "[FAIL] missing 'set -euo pipefail' in extract_session.sh" >&2
  exit 1
fi

set +e
ATRIUM_TEST_TRANSCRIPT_ROOT="$FIXTURE_DIR" \
  "$ADAPTER_DIR/extract_session.sh" \
    --session-id "nonexistent-session-xyz" \
    --cwd /tmp \
    --depth quick \
  >/dev/null 2>&1
EXIT_NOT_FOUND=$?
set -e
if [[ "$EXIT_NOT_FOUND" -ne 1 ]]; then
  echo "[FAIL] expected exit 1 for missing session, got $EXIT_NOT_FOUND" >&2
  exit 1
fi
echo "[PASS] exit code 1 on source-not-found"

run_depth() {
  local depth="$1" expected_min="$2"
  local tmp
  tmp="$(mktemp)"

  ATRIUM_TEST_TRANSCRIPT_ROOT="$FIXTURE_DIR" \
    "$ADAPTER_DIR/extract_session.sh" \
      --session-id "$SESSION_ID" \
      --cwd /tmp \
      --depth "$depth" \
    > "$tmp"

  local line_count
  line_count="$(wc -l < "$tmp" | tr -d ' ')"
  if [[ "$line_count" -lt "$expected_min" ]]; then
    echo "[FAIL] depth=$depth emitted $line_count lines, expected >= $expected_min" >&2
    cat "$tmp" >&2
    rm -f "$tmp"
    return 1
  fi

  python3 - "$SCHEMAS_DIR/canonical-event.schema.json" < "$tmp" <<'PY' || { rm -f "$tmp"; return 1; }
import json, sys
try:
    import jsonschema
except ImportError:
    print("[SKIP] jsonschema not available; line-level validation skipped", file=sys.stderr)
    sys.exit(0)
schema = json.load(open(sys.argv[1]))
validator = jsonschema.Draft202012Validator(schema)
errors = []
for i, line in enumerate(sys.stdin):
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError as e:
        errors.append(f"line {i+1}: invalid JSON: {e}")
        continue
    for err in validator.iter_errors(event):
        errors.append(f"line {i+1}: {err.message}")
if errors:
    for e in errors:
        print(f"[FAIL] {e}", file=sys.stderr)
    sys.exit(1)
PY
  echo "[PASS] depth=$depth ($line_count lines)"
  rm -f "$tmp"
}

# quick: session_start + session_end
run_depth quick 2
# standard: + user prose + assistant prose + 2 tool_use
run_depth standard 5
# deep: + tool_result for run_terminal_command only (read_file filtered)
run_depth deep 6

# Synthetic user_info dump must not become prose; user_query body must.
assert_user_query_only() {
  local tmp
  tmp="$(mktemp)"
  ATRIUM_TEST_TRANSCRIPT_ROOT="$FIXTURE_DIR" \
    "$ADAPTER_DIR/extract_session.sh" \
      --session-id "$SESSION_ID" \
      --cwd /tmp \
      --depth standard \
    > "$tmp"

  if grep -q 'OS Version: macos' "$tmp"; then
    echo "[FAIL] synthetic user_info prose leaked into standard extract" >&2
    cat "$tmp" >&2
    rm -f "$tmp"
    exit 1
  fi
  if ! grep -q 'Read the README and summarize' "$tmp"; then
    echo "[FAIL] real user_query prose missing from standard extract" >&2
    cat "$tmp" >&2
    rm -f "$tmp"
    exit 1
  fi
  if grep -q '"type": "reasoning"' "$tmp" || grep -q 'I should read the README' "$tmp"; then
    echo "[FAIL] reasoning content leaked into extract" >&2
    cat "$tmp" >&2
    rm -f "$tmp"
    exit 1
  fi
  echo "[PASS] user_query unwrapped; user_info + reasoning dropped"
  rm -f "$tmp"
}
assert_user_query_only

# deep emits run_terminal_command result but not read_file result body
assert_deep_filter() {
  local tmp
  tmp="$(mktemp)"
  ATRIUM_TEST_TRANSCRIPT_ROOT="$FIXTURE_DIR" \
    "$ADAPTER_DIR/extract_session.sh" \
      --session-id "$SESSION_ID" \
      --cwd /tmp \
      --depth deep \
    > "$tmp"
  if ! grep -q '3 README.md' "$tmp"; then
    echo "[FAIL] deep missing allowlisted shell tool_result" >&2
    cat "$tmp" >&2
    rm -f "$tmp"
    exit 1
  fi
  if grep -q 'A demo repo' "$tmp"; then
    echo "[FAIL] deep emitted non-allowlisted read_file tool_result" >&2
    cat "$tmp" >&2
    rm -f "$tmp"
    exit 1
  fi
  echo "[PASS] deep tool_result allowlist"
  rm -f "$tmp"
}
assert_deep_filter

echo "[PASS] grok extractor fixture suite"
