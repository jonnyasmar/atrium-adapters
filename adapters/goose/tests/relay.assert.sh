#!/usr/bin/env bash
set -euo pipefail

# relay.assert.sh — exercises the REAL relay route through goose-hook.sh:
#
#   native payload ──▶ goose-hook.sh <norm-event> <atrium-event>
#                        ──▶ normalize-hook-payload.sh <norm-event>
#                          ──▶ atrium hook emit <atrium-event> --adapter goose
#                                                --pane-id "$ATRIUM_PANE_ID" --json
#
# test-adapter.sh Phase 4 POSTs each fixture's expected JSON straight to
# /resolve under its directory basename, so it never runs goose-hook.sh and
# cannot observe the PostToolUseFailure -> post-tool-use fold or the pane-id
# handoff. This test does.
#
# Part 1 (hermetic, always): a stub `atrium` on ATRIUM_CLI_PATH records argv +
# stdin. Asserts the fold, the pane-id argument, the normalized body, and that
# the relay stays inert with no pane / in a chat pane.
#
# Part 2 (only when ~/.atrium-dev is running): emits through the real dev CLI
# and reads the event back from atrium, proving it is stored against the
# originating pane (not dropped as pane "unknown").

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR="$(cd "$HERE/.." && pwd)"
HOOK="$ADAPTER_DIR/goose-hook.sh"
FIX="$ADAPTER_DIR/tests/fixtures"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── stub atrium CLI ────────────────────────────────────────────────────
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
CAP_ARGV="$WORK/argv"
CAP_STDIN="$WORK/stdin"
cat > "$STUB_DIR/atrium" <<EOF
#!/usr/bin/env bash
printf '%s\0' "\$@" > "$CAP_ARGV"
cat > "$CAP_STDIN"
exit 0
EOF
chmod +x "$STUB_DIR/atrium"

FAILS=0
ok()   { printf '[PASS] %s\n' "$1"; }
bad()  { printf '[FAIL] %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }

reset_cap() { rm -f "$CAP_ARGV" "$CAP_STDIN"; }

# argv token $1 (1-indexed) from the NUL-separated capture (BSD awk has no NUL RS)
argv_at() { [ -f "$CAP_ARGV" ] && tr '\0' '\n' < "$CAP_ARGV" | sed -n "${1}p"; }
argv_joined() { [ -f "$CAP_ARGV" ] && tr '\0' ' ' < "$CAP_ARGV"; }

# This test may run inside an atrium pane, which exports the vars below — clear
# every one that could steer the relay or the CLI so each case sets exactly what
# it means to. ATRIUM_SOCKET matters most: socket routing outranks the CLI binary
# name, so an inherited socket would send `hook emit` to the spawning instance
# while the Part 2 readback hits a different instance's HTTP port.
SCRUB=(env -u ATRIUM_PANE_ID -u ATRIUM_CHAT_SDK_HOOKS -u ATRIUM_CLI_PATH
       -u ATRIUM_DATA_DIR -u ATRIUM_HOOK_PORT -u ATRIUM_ADAPTER_NAME
       -u ATRIUM_SOCKET)

run_hook() { # <norm-event> <atrium-event> <fixture-dir>
  reset_cap
  "${SCRUB[@]}" ATRIUM_CLI_PATH="$STUB_DIR/atrium" ATRIUM_PANE_ID="relay-test-pane" \
    "$HOOK" "$1" "$2" < "$FIX/$3/tool-input.json"
}

# ── Case A: PostToolUseFailure folds to post-tool-use, with pane id + error ──
run_hook post-tool-use-failure post-tool-use post-tool-use-failure
if [ ! -f "$CAP_ARGV" ]; then
  bad "A: relay did not invoke the atrium CLI"
else
  [ "$(argv_at 1)" = "hook" ] && [ "$(argv_at 2)" = "emit" ] \
    && [ "$(argv_at 3)" = "post-tool-use" ] \
    || bad "A: emitted event is not 'post-tool-use' (got: $(argv_joined))"
  [ "$(argv_at 3)" != "post-tool-use-failure" ] \
    || bad "A: failure event was not folded"
  grep -q -- '--adapter goose' <<<"$(argv_joined)" || bad "A: missing --adapter goose"
  grep -q -- "--pane-id relay-test-pane" <<<"$(argv_joined)" \
    || bad "A: pane id not passed to emit (got: $(argv_joined))"
  jq -e '
    (.error // "") != ""
    and (.tool_input | type) == "string"
    and .tool_input_json.command == "nonexistent_cmd_xyz_should_fail"
    and .session_id == "20260909_21"
  ' "$CAP_STDIN" >/dev/null \
    || bad "A: normalized body missing error / tool_input(_json) ($(cat "$CAP_STDIN"))"
  [ "$FAILS" -eq 0 ] && ok "PostToolUseFailure folds to post-tool-use with pane id + synthesized error"
fi

# ── Case B: a clean PostToolUse stays post-tool-use with no error ──
run_hook post-tool-use post-tool-use post-tool-use
[ "$(argv_at 3)" = "post-tool-use" ] || bad "B: clean post-tool-use mis-emitted ($(argv_joined))"
jq -e '((.error // "") == "") and (.tool_input_json.command == "echo GOOD-CALL")' "$CAP_STDIN" >/dev/null \
  || bad "B: clean post-tool-use body wrong ($(cat "$CAP_STDIN"))"
[ "$FAILS" -eq 0 ] && ok "clean PostToolUse relays as post-tool-use with no error"

# ── Case C: PreToolUse carries tool name + parsed input ──
run_hook pre-tool-use pre-tool-use pre-tool-use
[ "$(argv_at 3)" = "pre-tool-use" ] || bad "C: pre-tool-use mis-emitted ($(argv_joined))"
jq -e '(.tool_name == "shell") and (.tool_input_json.command == "echo GOOD-CALL")' "$CAP_STDIN" >/dev/null \
  || bad "C: pre-tool-use body wrong ($(cat "$CAP_STDIN"))"
[ "$FAILS" -eq 0 ] && ok "PreToolUse relays with tool_name + tool_input_json"

# ── Case D: no ATRIUM_PANE_ID -> completely inert ──
reset_cap
"${SCRUB[@]}" ATRIUM_CLI_PATH="$STUB_DIR/atrium" \
  "$HOOK" post-tool-use-failure post-tool-use < "$FIX/post-tool-use-failure/tool-input.json"
{ [ ! -f "$CAP_ARGV" ] && ok "no ATRIUM_PANE_ID: relay is inert (CLI never called)"; } \
  || bad "D: relay emitted without a pane id (would be dropped as pane 'unknown')"

# ── Case E: chat pane (ATRIUM_CHAT_SDK_HOOKS set) -> inert ──
reset_cap
"${SCRUB[@]}" ATRIUM_CHAT_SDK_HOOKS=1 ATRIUM_PANE_ID=relay-test-pane ATRIUM_CLI_PATH="$STUB_DIR/atrium" \
  "$HOOK" stop stop < "$FIX/stop/tool-input.json"
{ [ ! -f "$CAP_ARGV" ] && ok "chat pane: relay is inert (ACP turn bridge owns activity)"; } \
  || bad "E: relay double-fed a chat pane"

# ── Part 2: live tail against ONE real atrium instance, if one is resolvable ──
# Bind the emit and the readback to a single data dir so they cannot land on
# different instances: SCRUB clears the inherited ATRIUM_SOCKET, and we pass
# ATRIUM_DATA_DIR explicitly so the CLI derives that instance's socket. Override
# ATRIUM_RELAY_LIVE_DATA_DIR to point at a linked-worktree instance.
LIVE_DIR="${ATRIUM_RELAY_LIVE_DATA_DIR:-${HOME}/.atrium-dev}"
case "$(basename "$LIVE_DIR")" in
  .atrium-dev*) LIVE_CLI="${LIVE_DIR}/bin/atrium-dev" ;;
  *)            LIVE_CLI="${LIVE_DIR}/bin/atrium" ;;
esac
LIVE_PORT_FILE="${LIVE_DIR}/hook-port"
if [ "$FAILS" -eq 0 ] && [ -f "$LIVE_PORT_FILE" ] && [ -x "$LIVE_CLI" ]; then
  PORT="$(cat "$LIVE_PORT_FILE")"
  TOKEN="$(cat "${LIVE_DIR}/hook-token" 2>/dev/null || true)"
  PANE="relay-live-$$"
  "${SCRUB[@]}" ATRIUM_DATA_DIR="$LIVE_DIR" ATRIUM_CLI_PATH="$LIVE_CLI" ATRIUM_PANE_ID="$PANE" \
    "$HOOK" post-tool-use-failure post-tool-use < "$FIX/post-tool-use-failure/tool-input.json"
  sleep 0.3
  state="$(curl -sS -X POST "http://127.0.0.1:${PORT}/resolve" \
    -H 'Content-Type: application/json' \
    -H "X-Atrium-Hook-Token: ${TOKEN}" \
    -d "$(jq -n --arg p "$PANE" '{uri: ("atrium://hooks/_state?paneId=" + $p + "&limit=20")}')" 2>/dev/null || true)"
  if jq -e '
      [.events[] | select(.eventName == "post-tool-use")] | last
      | .payload.error != "" and (.payload.error != null)
    ' <<<"$state" >/dev/null 2>&1; then
    ok "live: folded failure stored against pane $PANE with a non-empty error"
  else
    bad "live: emit did not land a post-tool-use with an error under pane $PANE ($state)"
  fi
else
  printf '[SKIP] live tail (no atrium hook server under %s)\n' "$LIVE_DIR"
fi

if [ "$FAILS" -gt 0 ]; then
  printf 'relay.assert: %d failure(s)\n' "$FAILS" >&2
  exit 1
fi
printf 'relay.assert: all checks passed\n'
