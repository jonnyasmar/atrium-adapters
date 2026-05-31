#!/usr/bin/env bash
set -euo pipefail

# assert.sh — Deterministic test for the claude-code stop normalization.
#
# Verifies normalize-hook-payload.sh's `stop` branch scrapes the LAST
# text-bearing assistant turn out of a Claude transcript JSONL and
# injects it as `last_assistant_message`. Self-contained: points
# transcript_path at the in-repo transcript.jsonl, so it never depends
# on external /tmp state (unlike the static expected-atrium.json pair,
# which only asserts passthrough fields under test-adapter.sh because
# its /tmp transcript path is intentionally absent at runtime).

FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$(cd "$FIXTURE_DIR/../../.." && pwd)"
NORM="$ADAPTER_DIR/normalize-hook-payload.sh"
TRANSCRIPT="$FIXTURE_DIR/transcript.jsonl"

fail() {
  echo "[FAIL] $1" >&2
  [ "${2:-}" ] && echo "$2" >&2
  exit 1
}

# 1. Real transcript: last text-bearing assistant turn wins, the final
#    tool_use-only turn is skipped, and the two text blocks are joined
#    with a newline.
payload="$(jq -nc --arg t "$TRANSCRIPT" '{session_id:"fixture-cc-stop-001",transcript_path:$t,hook_event_name:"Stop"}')"
out="$(printf '%s' "$payload" | "$NORM" stop)"
echo "$out" | jq empty 2>/dev/null || fail "stop output is not valid JSON" "$out"

got="$(printf '%s' "$out" | jq -r '.last_assistant_message // empty')"
expected=$'There are 2 files in /tmp:\nfile1.txt and file2.txt.'
if [ "$got" != "$expected" ]; then
  fail "last_assistant_message mismatch" "expected: $(printf '%q' "$expected")"$'\n'"got:      $(printf '%q' "$got")"
fi
# Passthrough fields preserved.
[ "$(printf '%s' "$out" | jq -r '.session_id')" = "fixture-cc-stop-001" ] \
  || fail "session_id not preserved through stop enrichment" "$out"
echo "[PASS] stop: last_assistant_message = '$got'"

# 2. Fail-safe: missing transcript file → original payload verbatim, no
#    last_assistant_message key added.
miss="$(printf '%s' '{"session_id":"x","transcript_path":"/tmp/atrium-cc-nonexistent.jsonl"}' | "$NORM" stop)"
if printf '%s' "$miss" | jq -e 'has("last_assistant_message")' >/dev/null 2>&1; then
  fail "stop added last_assistant_message despite missing transcript" "$miss"
fi
[ "$(printf '%s' "$miss" | jq -r '.session_id')" = "x" ] || fail "fail-safe dropped fields" "$miss"
echo "[PASS] stop: missing transcript → payload verbatim"

# 3. Backward-compat: no event arg defaults to post-tool-use enrichment.
bc="$(printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/foo.txt"}}' | "$NORM")"
[ "$(printf '%s' "$bc" | jq -r '._atrium.writeKind')" = "edit" ] \
  || fail "backward-compat (no arg) lost post-tool-use _atrium enrichment" "$bc"
echo "[PASS] post-tool-use: no-arg backward compatibility preserved"

# 4. Static fixture pair matches (expected ⊂ actual), mirroring the
#    test-adapter.sh Phase-3 contract for this directory.
in_file="$FIXTURE_DIR/tool-input.json"
exp_file="$FIXTURE_DIR/expected-atrium.json"
act="$("$NORM" stop < "$in_file")"
diff_out="$(jq -n --argjson exp "$(cat "$exp_file")" --argjson act "$act" '
  def check($p; $e; $a):
    if ($e | type) == "object" then ($e | to_entries[] | check($p + [.key]; .value; $a[.key]))
    elif $e == $a then empty
    else { path: $p, expected: $e, actual: $a } end;
  [check([]; $exp; $act)]')"
[ "$diff_out" = "[]" ] || fail "static stop fixture diverges from expected-atrium.json" "$diff_out"
echo "[PASS] stop: static fixture pair (expected ⊂ actual)"

echo "[PASS] claude-code stop normalization fixture test complete"
