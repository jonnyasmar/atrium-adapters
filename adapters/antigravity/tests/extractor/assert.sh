#!/usr/bin/env bash
set -euo pipefail

# assert.sh — Smoke-test the claude-code extract_session.sh against a
# synthetic fixture transcript. Verifies depth filtering + canonical-
# schema conformance via jsonschema (line-level skipped if jsonschema
# absent — non-fatal).

ADAPTER_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION_ID="$(tr -d '[:space:]' < "$FIXTURE_DIR/fixture-session-id.txt")"
SCHEMAS_DIR="$(cd "$ADAPTER_DIR/../../schemas" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "[SKIP] python3 not available; cannot run extractor fixture test" >&2
  exit 0
fi

# Verify Python companion uses stdlib only (IB.5)
if [[ -f "$ADAPTER_DIR/extract_session.py" ]]; then
  THIRD_PARTY=$(grep -E "^(from|import) " "$ADAPTER_DIR/extract_session.py" \
    | grep -vE "^(from|import) (argparse|json|os|pathlib|re|sqlite3|sys|datetime|__future__|hashlib|time)\b" || true)
  if [[ -n "$THIRD_PARTY" ]]; then
    echo "[FAIL] extract_session.py uses third-party imports:" >&2
    echo "$THIRD_PARTY" >&2
    exit 1
  fi
fi

# Verify shebang + setopt (IB.8)
if ! head -1 "$ADAPTER_DIR/extract_session.sh" | grep -q "^#!/usr/bin/env bash$"; then
  echo "[FAIL] missing or wrong shebang in extract_session.sh" >&2
  exit 1
fi
if ! head -3 "$ADAPTER_DIR/extract_session.sh" | grep -q "^set -euo pipefail$"; then
  echo "[FAIL] missing 'set -euo pipefail' in extract_session.sh" >&2
  exit 1
fi

# Exit-code contract: source-not-found returns 1 (IB.6)
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

  # Validate each line against canonical-event.schema.json
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

run_depth quick 2
run_depth standard 4
run_depth deep 5

echo "[PASS] antigravity extractor fixture test complete"
