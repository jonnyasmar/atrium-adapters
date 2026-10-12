#!/usr/bin/env bash
# On Windows, Grok runs hook commands through PowerShell (and reads Claude
# Code's settings.json hooks too), so hooks.sh writes plain
# `<bash.exe> atrium-runtime-hook.sh <mode> …` commands there instead of the
# inline POSIX ones (issue #155). This pins, on any host:
#   - the Windows commands are plain words that PowerShell, cmd and Git Bash
#     all read the same way, and own the same hook slots as the POSIX install;
#   - each one does what the POSIX command it replaces does, input for input;
#   - upgrading a POSIX install leaves no POSIX atrium hook behind.
# A stub uname/cygpath stands in for Git Bash; the commands run under local bash.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/atrium-windows-hooks.XXXXXX)"
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

# Stand-in Git Bash: uname says MINGW64; cygpath prints POSIX paths unchanged
# (so the commands still run here) and gives Program Files and a data dir with
# a space an 8.3 name, unless CYGPATH_NO_SHORT is set.
WINBIN="$TMP/winbin"
mkdir -p "$WINBIN"
printf '#!/bin/sh\necho MINGW64_NT-10.0-26200\n' >"$WINBIN/uname"
cat >"$WINBIN/cygpath" <<'EOF'
#!/bin/sh
mode="$1"; path="$2"
[ "$path" = /usr/bin/bash.exe ] && path="C:/Program Files/Git/usr/bin/bash.exe"
case "$mode" in
  -m) printf '%s\n' "$path" ;;
  -ms)
    [ -z "${CYGPATH_NO_SHORT:-}" ] || { printf '%s\n' "$path"; exit 0; }
    printf '%s\n' "$path" | sed 's#Program Files#PROGRA~1#; s#atrium data#ATRIUM~1#'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WINBIN/uname" "$WINBIN/cygpath"
WIN_BASH="C:/PROGRA~1/Git/usr/bin/bash.exe"

# A data dir laid out the way atrium links adapters, under a path with a space
# so the 8.3 fallback is exercised; ATRIUM~1 is that short name.
PARENT="$TMP/p"
DATA="$PARENT/atrium data"
mkdir -p "$DATA/adapters"
ln -s "atrium data" "$PARENT/ATRIUM~1"
for adapter in claude-code grok shared; do
  ln -s "$ROOT/adapters/$adapter" "$DATA/adapters/$adapter"
done
SHORT_DATA="$PARENT/ATRIUM~1"

install() { # <adapter> <home> <windows|posix> [extra env…]
  local adapter="$1" home="$2" platform="$3"
  shift 3
  local path="$BASE_PATH"
  [ "$platform" = posix ] || path="$WINBIN:$BASE_PATH"
  mkdir -p "$home"
  env -i HOME="$home" PATH="$path" ATRIUM_DATA_DIR="$DATA" "$@" \
    bash "$ROOT/adapters/$adapter/hooks.sh" install 2>"$home/install.err" >/dev/null
}

install grok "$TMP/grok-win" windows
install grok "$TMP/grok-posix" posix
install claude-code "$TMP/claude-win" windows
install claude-code "$TMP/claude-posix" posix
GROK_WIN="$TMP/grok-win/.grok/hooks/atrium-grok.json"
GROK_POSIX="$TMP/grok-posix/.grok/hooks/atrium-grok.json"
CLAUDE_WIN="$TMP/claude-win/.claude/settings.json"
CLAUDE_POSIX="$TMP/claude-posix/.claude/settings.json"

# --- shape --------------------------------------------------------------------

# Every command: the bash.exe path, the adapter's entry under the shortened
# data dir, then plain words. Nothing PowerShell, cmd or Grok would read as
# shell syntax: no quotes, $, ;, |, &, [, (, =, spaces in a path.
check_shape() {
  local label="$1" file="$2" adapter="$3" prefix bad
  prefix="$WIN_BASH $SHORT_DATA/adapters/$adapter/atrium-runtime-hook.sh "
  bad="$(jq -r --arg prefix "$prefix" '
    [.hooks[][].hooks[].command]
    | map(select((startswith($prefix) and test("^[A-Za-z0-9_.~/:-]+( [A-Za-z0-9_.~/:-]+)+$")) | not))
    | .[]' "$file")"
  expect "$label: every command is plain words" "" "$bad"
}
check_shape "grok" "$GROK_WIN" grok
check_shape "claude-code" "$CLAUDE_WIN" claude-code

# Same events, same handler count and matchers per event as the POSIX install.
slots() { jq -c '.hooks | to_entries | map({key, value: [.value[] | {matcher, n: (.hooks | length)}]})' "$1"; }
expect "grok: same hook slots as POSIX" "$(slots "$GROK_POSIX")" "$(slots "$GROK_WIN")"
expect "claude-code: same hook slots as POSIX" "$(slots "$CLAUDE_POSIX")" "$(slots "$CLAUDE_WIN")"

expect "grok status sees the Windows install" '{"subcommand": "status", "installed": true, "activityHooks": true}' \
  "$(env -i HOME="$TMP/grok-win" PATH="$WINBIN:$BASE_PATH" ATRIUM_DATA_DIR="$DATA" bash "$ROOT/adapters/grok/hooks.sh" status)"
expect "claude-code status sees the Windows install" '{"subcommand": "status", "installed": true, "activityHooks": true}' \
  "$(env -i HOME="$TMP/claude-win" PATH="$WINBIN:$BASE_PATH" ATRIUM_DATA_DIR="$DATA" bash "$ROOT/adapters/claude-code/hooks.sh" status)"

# --- upgrade ------------------------------------------------------------------

# A POSIX install upgraded on Windows keeps the user's own hook and no POSIX
# atrium command; a second install changes nothing.
UPGRADE="$TMP/claude-upgrade"
install claude-code "$UPGRADE" posix
jq '.hooks.Stop += [{matcher: ".*", hooks: [{type: "command", command: "my-own-hook.sh"}]}]' \
  "$UPGRADE/.claude/settings.json" >"$UPGRADE/s.json" && mv "$UPGRADE/s.json" "$UPGRADE/.claude/settings.json"
install claude-code "$UPGRADE" windows
expect "upgrade: no POSIX atrium command survives" "0" \
  "$(jq '[.hooks[][].hooks[].command | select(test("ATRIUM_HOOK_MARKER|claude-hook-entry|inject-context"))] | length' "$UPGRADE/.claude/settings.json")"
expect "upgrade: the user's own hook survives" "1" \
  "$(jq '[.hooks.Stop[].hooks[].command | select(. == "my-own-hook.sh")] | length' "$UPGRADE/.claude/settings.json")"
before="$(cat "$UPGRADE/.claude/settings.json")"
install claude-code "$UPGRADE" windows
expect "upgrade: reinstall is a no-op" "$before" "$(cat "$UPGRADE/.claude/settings.json")"

# --- no plain path --------------------------------------------------------------

install grok "$TMP/grok-noshort" windows CYGPATH_NO_SHORT=1
expect "no 8.3 name: grok keeps the POSIX commands" "0" \
  "$(jq '[.hooks[][].hooks[].command | select(startswith("C:/"))] | length' "$TMP/grok-noshort/.grok/hooks/atrium-grok.json")"
expect "no 8.3 name: same hook slots as POSIX" "$(slots "$GROK_POSIX")" \
  "$(slots "$TMP/grok-noshort/.grok/hooks/atrium-grok.json")"
if grep -q "no space-free path" "$TMP/grok-noshort/install.err"; then
  pass "no 8.3 name: install says why"
else
  fail "no 8.3 name: install says why"
fi

# --- behaviour parity -----------------------------------------------------------

# Stub CLI: records each call, answers the context commands with something
# recognisable. Stub curl: the hook server's reply for inject-context.sh.
STUB_CLI="$TMP/atrium"
cat >"$STUB_CLI" <<'EOF'
#!/bin/sh
input="$(cat)"
echo "cli:$*|${#input}" >>"$EMIT_LOG"
case "$1 $2" in
  "skills resolve-manifest") echo "manifest:$8" ;;
  "skills resolve-prompt-sigils") echo '{"sigils":true}' ;;
esac
exit 0
EOF
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
printf '#!/bin/sh\ncat >/dev/null\necho '"'"'{"atriumContext":"ctx"}'"'"'\n' >"$STUBS/curl"
chmod +x "$STUB_CLI" "$STUBS/curl"
printf '4242' >"$DATA/hook-port"

# Runs a command with one environment; prints "<cli calls>|<stdout>".
# `posix` commands go through bash -c like a POSIX host; `windows` ones drop
# the bash.exe word and run the entry under local bash. The pane's data dir is
# the space-free alias: the POSIX inject commands leave it unquoted.
run_hook() { # <posix|windows> <command> <payload> [env…]
  local kind="$1" command="$2" payload="$3" out
  shift 3
  : >"$TMP/calls"
  local -a argv
  if [ "$kind" = posix ]; then
    argv=(bash -c "$command")
  else
    read -r -a argv <<<"$command"
    argv[0]=bash
  fi
  out="$(printf '%s' "$payload" | env -i HOME="$TMP/home" PATH="$STUBS:$BASE_PATH" \
    ATRIUM_DATA_DIR="$SHORT_DATA" ATRIUM_CLI_PATH="$STUB_CLI" EMIT_LOG="$TMP/calls" "$@" "${argv[@]}" 2>/dev/null)"
  printf '%s|%s' "$(tr '\n' ';' <"$TMP/calls")" "$out"
}

ENVS=(
  "outside:"
  "pane:ATRIUM=1 ATRIUM_PANE_ID=pane-1"
  "stray-pane:ATRIUM_PANE_ID=stray"
  "chat:ATRIUM=1 ATRIUM_PANE_ID=pane-1 ATRIUM_CHAT_SDK_HOOKS=1"
  "cursor:ATRIUM=1 ATRIUM_PANE_ID=pane-1 CURSOR_INVOKED_AS=cursor-agent"
)

# Pairs every POSIX handler with the Windows handler in the same slot and runs
# both through each environment.
check_parity() { # <label> <posix file> <windows file> <payload>
  local label="$1" posix="$2" windows="$3" payload="$4" n i pcmd wcmd slot entry name vars
  n="$(jq '[.hooks[][].hooks[]] | length' "$posix")"
  for ((i = 0; i < n; i++)); do
    pcmd="$(jq -r --argjson i "$i" '[.hooks[][].hooks[].command][$i]' "$posix")"
    wcmd="$(jq -r --argjson i "$i" '[.hooks[][].hooks[].command][$i]' "$windows")"
    slot="$(jq -r --argjson i "$i" '[.hooks | to_entries[] | .key as $k | .value[] | .hooks[] | $k][$i]' "$posix")"
    for entry in "${ENVS[@]}"; do
      name="${entry%%:*}"
      vars="${entry#*:}"
      # shellcheck disable=SC2086
      expect "$label $slot #$i ($name): ${wcmd#* * }" \
        "$(run_hook posix "$pcmd" "$payload" $vars)" "$(run_hook windows "$wcmd" "$payload" $vars)"
    done
  done
}

GROK_PAYLOAD='{"hookEventName":"pre_tool_use","sessionId":"s1","toolName":"bash","toolInput":{"command":"ls"},"prompt":"hi"}'
CLAUDE_PAYLOAD='{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"},"prompt":"hi"}'
check_parity "grok" "$GROK_POSIX" "$GROK_WIN" "$GROK_PAYLOAD"
check_parity "claude-code" "$CLAUDE_POSIX" "$CLAUDE_WIN" "$CLAUDE_PAYLOAD"

# Grok runs settings.json hooks as well, with GROK_HOOK_EVENT set; on Windows
# those duplicates of its own hooks stay silent even inside a pane.
grok_ran=""
while IFS= read -r wcmd; do
  out="$(run_hook windows "$wcmd" "$GROK_PAYLOAD" ATRIUM=1 ATRIUM_PANE_ID=pane-1 GROK_HOOK_EVENT=pre_tool_use)"
  [ "$out" = "|" ] || grok_ran="$grok_ran ${wcmd#* * }=>$out"
done < <(jq -r '.hooks[][].hooks[].command' "$CLAUDE_WIN")
expect "claude-code hooks under Grok do nothing" "" "$grok_ran"

if [ "$FAILURES" -ne 0 ]; then
  printf '%d failure(s)\n' "$FAILURES"
  exit 1
fi
