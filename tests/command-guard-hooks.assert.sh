#!/usr/bin/env bash
# The catastrophic-command guard (`atrium guard check --adapter <name>`) rides
# each adapter's own pre-tool hook. This pins, per adapter and without a real
# CLI:
#   - the guard runs in atrium panes, terminal and chat alike, and nowhere else;
#   - the CLI's refusal reaches the agent CLI as the hook's stdout, unchanged;
#   - an allowed command leaves the hook's normal answer untouched;
#   - an atrium CLI from before `guard` (usage error on stderr, exit 2) can
#     never block a command: the hook still exits 0 with its normal answer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/atrium-guard-hooks.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

pass() { printf '[PASS] %s\n' "$1"; }
fail() {
  printf '[FAIL] %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}
expect() {
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1: expected [$2], got [$3]"; fi
}

JQ_DIR="$(dirname "$(command -v jq)")"
BASE_PATH="/usr/bin:/bin:$JQ_DIR"

DATA="$TMP/data"
mkdir -p "$DATA/adapters"
for dir in "$ROOT"/adapters/*/; do
  ln -s "$dir" "$DATA/adapters/$(basename "$dir")"
done

# A current CLI: refuses any payload naming the refusal sentinel with a
# recognisable envelope, prints nothing otherwise, and logs every call.
NEW_CLI="$TMP/new-atrium"
cat >"$NEW_CLI" <<'EOF'
#!/bin/sh
input="$(cat)"
echo "$*" >>"$CALLS"
if [ "$1 $2" = "guard check" ]; then
  case "$input" in
    *atrium-guard-test-refuse*) printf '{"refused":"%s"}\n' "$4" ;;
  esac
fi
exit 0
EOF
# A CLI from before `guard`: clap's usage error on stderr and exit 2.
OLD_CLI="$TMP/old-atrium"
cat >"$OLD_CLI" <<'EOF'
#!/bin/sh
cat >/dev/null
echo "$*" >>"$CALLS"
if [ "$1" = guard ]; then
  echo "error: unrecognized subcommand 'guard'" >&2
  exit 2
fi
exit 0
EOF
chmod +x "$NEW_CLI" "$OLD_CLI"
CALLS="$TMP/calls"

install() { # <adapter> <home>
  mkdir -p "$2"
  env -i HOME="$2" PATH="$BASE_PATH" ATRIUM_DATA_DIR="$DATA" \
    bash "$DATA/adapters/$1/hooks.sh" install >/dev/null 2>"$2/install.err"
}

# Runs one hook; prints "<guard calls>|<stdout>|<exit>".
run() { # <cli> <payload> <env words> -- <argv…>
  local cli="$1" payload="$2" vars="$3" out code
  shift 4
  : >"$CALLS"
  # shellcheck disable=SC2086
  out="$(printf '%s' "$payload" | env -i HOME="$TMP/home" PATH="$BASE_PATH" ATRIUM_HOOK_DEBUG=0 \
    ATRIUM_DATA_DIR="$DATA" ATRIUM_CLI_PATH="$cli" CALLS="$CALLS" $vars "$@" 2>/dev/null)" && code=0 || code=$?
  printf '%s|%s|%s' "$(grep -c '^guard check' "$CALLS" || true)" "$out" "$code"
}

PANE="ATRIUM=1 ATRIUM_PANE_ID=pane-1"
CHAT="ATRIUM=1 ATRIUM_PANE_ID=pane-1 ATRIUM_CHAT_SDK_HOOKS=1"

# check <label> <adapter> <refuse payload> <allow payload> <normal stdout> -- <argv…>
check() {
  local label="$1" adapter="$2" refuse="$3" allow="$4" normal="$5" deny
  shift 6
  deny="{\"refused\":\"$adapter\"}"
  expect "$label: refuses in a pane" "1|$deny|0" "$(run "$NEW_CLI" "$refuse" "$PANE" -- "$@")"
  expect "$label: refuses in a chat pane" "1|$deny|0" "$(run "$NEW_CLI" "$refuse" "$CHAT" -- "$@")"
  expect "$label: allows in a pane" "1|$normal|0" "$(run "$NEW_CLI" "$allow" "$PANE" -- "$@")"
  expect "$label: an old CLI never blocks" "1|$normal|0" "$(run "$OLD_CLI" "$refuse" "$PANE" -- "$@")"
  local outside
  outside="$(run "$NEW_CLI" "$refuse" "" -- "$@")"
  expect "$label: does nothing outside atrium" "0" "${outside%%|*}"
}

# --- adapters whose guard is its own config entry --------------------------

guard_entry() { # <adapter> <home> <config> <jq listing {matcher, command}>
  install "$1" "$2"
  jq -c "$4" "$2/$3"
}

entry_checks() { # <adapter> <config> <jq> <matcher> <refuse> <allow>
  local adapter="$1" config="$2" filter="$3" matcher="$4" refuse="$5" allow="$6" home entries cmd
  home="$TMP/$adapter-home"
  entries="$(guard_entry "$adapter" "$home" "$config" "$filter")"
  expect "$adapter: one guard entry" "1" "$(printf '%s\n' "$entries" | grep -c . || true)"
  expect "$adapter: guard matcher" "$matcher" "$(jq -r '.matcher' <<<"$entries")"
  cmd="$(jq -r '.command' <<<"$entries")"
  check "$adapter" "$adapter" "$refuse" "$allow" "" -- bash -c "$cmd"
  # Reinstalling replaces the entry instead of adding a second one.
  install "$adapter" "$home"
  expect "$adapter: reinstall keeps one guard entry" "1" \
    "$(jq -c "$filter" "$home/$config" | grep -c . || true)"
}

entry_checks claude-code .claude/settings.json \
  '.hooks.PreToolUse[] | {matcher, command: .hooks[].command} | select(.command | test("guard check"))' \
  'Bash|PowerShell|Monitor' \
  '{"session_id":"s","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"atrium-guard-test-refuse"}}' \
  '{"session_id":"s","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}'

entry_checks codex .codex/hooks.json \
  '.hooks.PreToolUse[] | {matcher, command: .hooks[].command} | select(.command | test("guard check"))' \
  'Bash' \
  '{"session_id":"s","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"atrium-guard-test-refuse"}}' \
  '{"session_id":"s","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}'

entry_checks grok .grok/hooks/atrium-grok.json \
  '.hooks.PreToolUse[] | {matcher, command: .hooks[].command} | select(.command | test("guard check"))' \
  'Bash' \
  '{"sessionId":"s","toolName":"run_terminal_command","toolInput":{"command":"atrium-guard-test-refuse"}}' \
  '{"sessionId":"s","toolName":"run_terminal_command","toolInput":{"command":"ls"}}'

entry_checks cursor-agent .cursor/hooks.json \
  '.hooks.preToolUse[] | {matcher, command} | select(.command | test("guard check"))' \
  'Shell' \
  '{"conversation_id":"c","tool_name":"Shell","tool_input":{"command":"atrium-guard-test-refuse"}}' \
  '{"conversation_id":"c","tool_name":"Shell","tool_input":{"command":"ls"}}'

# Grok and Cursor also run ~/.claude/settings.json hooks; the claude-code
# guard leaves those to their own entries.
claude_guard="$(jq -r '.hooks.PreToolUse[].hooks[].command | select(test("guard check"))' \
  "$TMP/claude-code-home/.claude/settings.json")"
refuse_claude='{"session_id":"s","tool_name":"Bash","tool_input":{"command":"atrium-guard-test-refuse"}}'
for foreign in "GROK_HOOK_EVENT=PreToolUse" "CURSOR_INVOKED_AS=cursor-agent"; do
  out="$(run "$NEW_CLI" "$refuse_claude" "$PANE $foreign" -- bash -c "$claude_guard")"
  expect "claude-code guard under ${foreign%%=*} does nothing" "0" "${out%%|*}"
done

# --- adapters whose guard lives in their hook script ------------------------

check "goose" goose \
  '{"session_id":"s","tool_name":"developer__shell","tool_input":{"command":"atrium-guard-test-refuse"}}' \
  '{"session_id":"s","tool_name":"developer__shell","tool_input":{"command":"ls"}}' \
  "" -- bash "$ROOT/adapters/goose/goose-hook.sh" pre-tool-use pre-tool-use

check "hermes" hermes \
  '{"session_id":"s","tool_name":"terminal","tool_input":{"command":"atrium-guard-test-refuse"}}' \
  '{"session_id":"s","tool_name":"terminal","tool_input":{"command":"ls"}}' \
  "{}" -- bash "$ROOT/adapters/hermes/hermes-hook.sh" pre_tool_call

check "antigravity" antigravity \
  '{"conversationId":"c","toolCall":{"name":"run_command","args":{"CommandLine":"atrium-guard-test-refuse"}}}' \
  '{"conversationId":"c","toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}' \
  '{"decision":"allow"}' -- bash "$ROOT/adapters/antigravity/agy-hook-entry.sh" pre-tool-use

check "copilot" copilot \
  '{"sessionId":"s","toolName":"bash","toolArgs":{"command":"atrium-guard-test-refuse"}}' \
  '{"sessionId":"s","toolName":"bash","toolArgs":{"command":"ls"}}' \
  "{}" -- bash "$ROOT/adapters/copilot/copilot-hook.sh" preToolUse

check "kimi" kimi \
  '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"atrium-guard-test-refuse"}}' \
  '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"}}' \
  "" -- bash "$ROOT/adapters/kimi/kimi-hook.sh" pre-tool-use pre-tool-use

# Tools that cannot run a shell command never cost a guard call.
out="$(run "$NEW_CLI" '{"tool_name":"developer__text_editor","tool_input":{"path":"a"}}' "$PANE" -- \
  bash "$ROOT/adapters/goose/goose-hook.sh" pre-tool-use pre-tool-use)"
expect "goose: a non-shell tool skips the guard" "0" "${out%%|*}"
out="$(run "$NEW_CLI" '{"tool_name":"read_file","tool_input":{"path":"a"}}' "$PANE" -- \
  bash "$ROOT/adapters/hermes/hermes-hook.sh" pre_tool_call)"
expect "hermes: a non-shell tool skips the guard" "0|{}|0" "$out"
out="$(run "$NEW_CLI" '{"toolCall":{"name":"view_file","args":{}}}' "$PANE" -- \
  bash "$ROOT/adapters/antigravity/agy-hook-entry.sh" pre-tool-use)"
expect "antigravity: a non-shell tool skips the guard" '0|{"decision":"allow"}|0' "$out"

if [ "$FAILURES" -ne 0 ]; then
  printf '%d failure(s)\n' "$FAILURES"
  exit 1
fi
