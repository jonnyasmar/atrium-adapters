#!/usr/bin/env bash
# The global hook configs atrium installs fire for every session of the tool,
# inside atrium or not. Only an atrium pane can attribute an event, so the
# lifecycle hooks must not call `atrium hook emit` without ATRIUM_PANE_ID —
# while still answering each tool's stdout contract (issue #140).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/atrium-hook-guards.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

pass() { printf '[PASS] %s\n' "$1"; }
fail() {
  printf '[FAIL] %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

STUB_CLI="$TMP/atrium"
printf '#!/bin/sh\ncat >/dev/null\necho "emit:$*" >>"$EMIT_LOG"\nexit 0\n' >"$STUB_CLI"
chmod +x "$STUB_CLI"

# Installed hook commands reach scripts through ATRIUM_DATA_DIR, so point one
# at this checkout the way atrium's adapters/<name> links do.
DATA="$TMP/data"
mkdir -p "$DATA/adapters"
for adapter in codex grok cursor-agent antigravity; do
  ln -s "$ROOT/adapters/$adapter" "$DATA/adapters/$adapter"
done
BASE_PATH="/usr/bin:/bin:$(dirname "$(command -v jq)")"

# Runs `$1` (a shell command string) with the given pane id ("" = unset);
# prints "<emits>|<stdout>".
run_command() {
  local command="$1" pane="$2" payload="$3" out
  : >"$TMP/emits"
  if [ -n "$pane" ]; then
    out="$(printf '%s' "$payload" | env -i HOME="$TMP/home" PATH="$BASE_PATH" \
      ATRIUM=1 ATRIUM_PANE_ID="$pane" ATRIUM_DATA_DIR="$DATA" ATRIUM_CLI_PATH="$STUB_CLI" \
      EMIT_LOG="$TMP/emits" ATRIUM_HOOK_DEBUG=0 bash -c "$command")"
  else
    out="$(printf '%s' "$payload" | env -i HOME="$TMP/home" PATH="$BASE_PATH" \
      ATRIUM_DATA_DIR="$DATA" ATRIUM_CLI_PATH="$STUB_CLI" \
      EMIT_LOG="$TMP/emits" ATRIUM_HOOK_DEBUG=0 bash -c "$command")"
  fi
  printf '%s|%s' "$(wc -l <"$TMP/emits" | tr -d ' ')" "$out"
}

expect() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label: expected [$expected], got [$actual]"
  fi
}

# codex and grok: lifecycle commands live in their hook files.
install_into() {
  local adapter="$1" home="$TMP/home-$1"
  mkdir -p "$home"
  env -i HOME="$home" PATH="$BASE_PATH" ATRIUM_DATA_DIR="$DATA" \
    bash "$ROOT/adapters/$adapter/hooks.sh" install >/dev/null
}
install_into codex
install_into grok
mkdir -p "$TMP/home"

CODEX_HOOKS="$TMP/home-codex/.codex/hooks.json"
codex_cmd() {
  jq -r --arg key "$1" --arg event "$2" \
    '.hooks[$key][].hooks[].command | select(test("hook emit " + $event + " "))' "$CODEX_HOOKS"
}
PAYLOAD='{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}'
cmd="$(codex_cmd PreToolUse pre-tool-use)"
expect "codex pre-tool-use outside a pane: no emit" "0|" "$(run_command "$cmd" "" "$PAYLOAD")"
expect "codex pre-tool-use in a pane: emits" "1|" "$(run_command "$cmd" pane-1 "$PAYLOAD")"
cmd="$(codex_cmd UserPromptSubmit user-prompt-submit)"
expect "codex user-prompt-submit outside a pane: {} and no emit" "0|{}" "$(run_command "$cmd" "" "$PAYLOAD")"
expect "codex user-prompt-submit in a pane: emits, then {}" "1|{}" "$(run_command "$cmd" pane-1 "$PAYLOAD")"

GROK_HOOKS="$TMP/home-grok/.grok/hooks/atrium-grok.json"
cmd="$(jq -r '.hooks.PreToolUse[].hooks[].command | select(test("hook emit pre-tool-use "))' "$GROK_HOOKS")"
GROK_PAYLOAD='{"hookEventName":"pre_tool_use","sessionId":"s1","toolName":"bash","toolInput":{"command":"ls"}}'
expect "grok pre-tool-use outside a pane: no emit" "0|" "$(run_command "$cmd" "" "$GROK_PAYLOAD")"
expect "grok pre-tool-use in a pane: emits" "1|" "$(run_command "$cmd" pane-1 "$GROK_PAYLOAD")"

# cursor-agent and antigravity: the hook command is the entry script itself.
CURSOR_ENTRY="\"$DATA/adapters/cursor-agent/cursor-hook-entry.sh\" pre-tool-use"
CURSOR_PAYLOAD='{"conversation_id":"c1","hook_event_name":"preToolUse","tool_name":"Shell"}'
expect "cursor-agent outside a pane: no emit" "0|" "$(run_command "$CURSOR_ENTRY" "" "$CURSOR_PAYLOAD")"
expect "cursor-agent in a pane: emits" "1|" "$(run_command "$CURSOR_ENTRY" pane-1 "$CURSOR_PAYLOAD")"

# atrium installs every .sh as 0755; the checkout need not carry the bit.
AGY_ENTRY="bash \"$DATA/adapters/antigravity/agy-hook-entry.sh\""
AGY_PAYLOAD='{"conversationId":"x","toolCall":{"name":"run_command"},"fullyIdle":true}'
expect "antigravity pre-tool-use outside a pane: allow, no emit" '0|{"decision":"allow"}' \
  "$(run_command "$AGY_ENTRY pre-tool-use" "" "$AGY_PAYLOAD")"
expect "antigravity post-tool-use outside a pane: {}, no emit" "0|{}" \
  "$(run_command "$AGY_ENTRY post-tool-use" "" "$AGY_PAYLOAD")"
expect "antigravity stop outside a pane: {}, no emit" "0|{}" \
  "$(run_command "$AGY_ENTRY stop" "" "$AGY_PAYLOAD")"
expect "antigravity pre-tool-use in a pane: allow and emits" '1|{"decision":"allow"}' \
  "$(run_command "$AGY_ENTRY pre-tool-use" pane-1 "$AGY_PAYLOAD")"

if [ "$FAILURES" -ne 0 ]; then
  printf '%d failure(s)\n' "$FAILURES"
  exit 1
fi
