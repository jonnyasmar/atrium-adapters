#!/usr/bin/env bash
# Session listers must reach a usable Python 3 where `python3` is not one
# (Windows: the Microsoft Store alias stub, while python.org and conda installs
# answer to `python` or `py -3`), and codex must match the Windows cwd
# spellings its own thread registry stores (issue #151).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/atrium-list-python.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
REAL_PYTHON="$(command -v python3)"

pass() { printf '[PASS] %s\n' "$1"; }
fail() {
  printf '[FAIL] %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

# `python` is a logging shim over the real interpreter; the WindowsApps-shaped
# `python3` is a stub that logs and runs nothing, like the Store alias.
BIN="$TMP/bin"
STUB_DIR="$TMP/AppData/Local/Microsoft/WindowsApps"
mkdir -p "$BIN" "$STUB_DIR"
printf '#!/bin/sh\necho python >>"$INTERPRETER_LOG"\nexec "%s" "$@"\n' "$REAL_PYTHON" >"$BIN/python"
printf '#!/bin/sh\necho stub >>"$INTERPRETER_LOG"\nexit 9009\n' >"$STUB_DIR/python3"
chmod +x "$BIN/python" "$STUB_DIR/python3"
# Listers may use coreutils; the PATH must not reach a real python3, though.
ln -s "$(command -v dirname)" "$BIN/dirname"

# `py` is the Windows launcher: only `py -3 …` may reach the interpreter.
PYL_BIN="$TMP/pylauncher"
mkdir -p "$PYL_BIN"
printf '#!/bin/sh\n[ "$1" = -3 ] || { echo "py without -3" >>"$INTERPRETER_LOG"; exit 2; }\nshift\necho python >>"$INTERPRETER_LOG"\nexec "%s" "$@"\n' "$REAL_PYTHON" >"$PYL_BIN/py"
chmod +x "$PYL_BIN/py"
ln -s "$(command -v dirname)" "$PYL_BIN/dirname"

HOME_FIXTURE="$TMP/home"
mkdir -p \
  "$HOME_FIXTURE/.gemini/antigravity-cli/cache" \
  "$HOME_FIXTURE/.cursor/chats" \
  "$HOME_FIXTURE/.local/share/opencode" \
  "$HOME_FIXTURE/.omp/agent/sessions" \
  "$HOME_FIXTURE/.pi/agent/sessions" \
  "$HOME_FIXTURE/.codex/sessions"
printf '[]\n' >"$HOME_FIXTURE/.gemini/antigravity-cli/cache/last_conversations.json"

assert_uses_python() {
  local adapter="$1" path_value="$2" label="$3"
  local log="$TMP/$adapter.log" output
  : >"$log"
  if ! output="$(env -i HOME="$HOME_FIXTURE" PATH="$path_value" INTERPRETER_LOG="$log" \
    "$BASH" "$ROOT/adapters/$adapter/list_recent_sessions.sh" "$TMP/workspace" 2>/dev/null)"; then
    fail "$adapter $label: lister exited unsuccessfully"
  elif ! jq -e '.sessions | type == "array"' <<<"$output" >/dev/null 2>&1; then
    fail "$adapter $label: invalid output: $output"
  elif grep -q -e stub -e "py without -3" "$log"; then
    fail "$adapter $label: ran the alias stub or \`py\` without -3"
  elif ! grep -q python "$log"; then
    fail "$adapter $label: never reached \`python\`"
  else
    pass "$adapter $label"
  fi
}

for adapter in codex antigravity cursor-agent muse opencode omp pi; do
  assert_uses_python "$adapter" "$BIN" "falls back to \`python\` without python3"
  assert_uses_python "$adapter" "$PYL_BIN" "falls back to \`py -3\` without python3 or python"
  if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    assert_uses_python "$adapter" "$STUB_DIR:$BIN" "skips the WindowsApps python3 alias"
  else
    printf '[SKIP] %s alias-stub case needs bash >= 4 (Git Bash is 5)\n' "$adapter"
  fi
done

# A python3 that fails must fall through to Strategy 2 rather than abort the
# codex lister under `set -e` with nothing on stdout.
BROKEN="$TMP/broken"
mkdir -p "$BROKEN"
printf '#!/bin/sh\nexit 1\n' >"$BROKEN/python3"
chmod +x "$BROKEN/python3"
if output="$(env -i HOME="$HOME_FIXTURE" PATH="$BROKEN" \
  "$BASH" "$ROOT/adapters/codex/list_recent_sessions.sh" "$TMP/workspace" 2>/dev/null)" \
  && [ "$output" = '{"sessions": []}' ]; then
  pass "codex survives a failing interpreter"
else
  fail "codex survives a failing interpreter (output: ${output:-<none>})"
fi

assert_codex_ids() {
  local label="$1" expected="$2" home="$3" cwd="$4"
  local output actual
  if ! output="$(env HOME="$home" "$BASH" "$ROOT/adapters/codex/list_recent_sessions.sh" "$cwd" 2>/dev/null)"; then
    fail "$label: lister exited unsuccessfully"
  elif ! actual="$(jq -cer '[.sessions[] | [.id, .name]]' <<<"$output")"; then
    fail "$label: invalid output: $output"
  elif [ "$actual" != "$expected" ]; then
    fail "$label: expected $expected, got $actual"
  else
    pass "$label"
  fi
}

# Codex's registry stores `\\?\D:\…`; atrium asks with another spelling.
REGISTRY_HOME="$TMP/registry-home"
mkdir -p "$REGISTRY_HOME/.codex"
"$REAL_PYTHON" - "$REGISTRY_HOME/.codex" <<'PY'
import os, sqlite3, sys
codex = sys.argv[1]
rollout = os.path.join(codex, 'rollout-win.jsonl')
open(rollout, 'w').write('{}\n')
conn = sqlite3.connect(os.path.join(codex, 'state_5.sqlite'))
conn.execute('CREATE TABLE threads(id TEXT, cwd TEXT, title TEXT, updated_at INTEGER, first_user_message TEXT, archived INTEGER, thread_source TEXT, rollout_path TEXT, recency_at_ms INTEGER)')
rows = [
    ('codex-win', '\\\\?\\D:\\Proj\\Codex', 'windows title', 1784635200, '', 0, 'user', rollout, 1784635200000),
    ('codex-other', '\\\\?\\D:\\Proj\\Other', 'other dir', 1784635300, '', 0, 'user', rollout, 1784635300000),
]
conn.executemany('INSERT INTO threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)', rows)
conn.commit()
PY
assert_codex_ids "codex registry matches a \\\\?\\ cwd" \
  '[["codex-win","windows title"]]' "$REGISTRY_HOME" 'D:\Proj\Codex'
assert_codex_ids "codex registry folds drive case, separators and a trailing slash" \
  '[["codex-win","windows title"]]' "$REGISTRY_HOME" 'd:/proj/codex/'

# Without Python the sqlite3 CLI fallback must match the same spellings, and
# report the folder the way atrium asked for it.
SQLITE_ONLY="$TMP/sqlite-only"
mkdir -p "$SQLITE_ONLY"
ln -s "$(command -v sqlite3)" "$SQLITE_ONLY/sqlite3"
ln -s "$(command -v jq)" "$SQLITE_ONLY/jq"
for asked in 'D:\Proj\Codex' 'd:/Proj/Codex/'; do
  if ! output="$(env -i HOME="$REGISTRY_HOME" PATH="$SQLITE_ONLY" \
    "$BASH" "$ROOT/adapters/codex/list_recent_sessions.sh" "$asked" 2>/dev/null)"; then
    fail "codex sqlite3 fallback for $asked: lister exited unsuccessfully"
  elif ! jq -e --arg asked "$asked" \
    '[.sessions[] | [.id, .name, .cwd]] == [["codex-win", "windows title", $asked]]' \
    <<<"$output" >/dev/null; then
    fail "codex sqlite3 fallback for $asked: got $output"
  else
    pass "codex sqlite3 fallback matches a \\\\?\\ cwd asked as $asked"
  fi
done

# The rollout fallback compares session_meta.cwd the same way.
ROLLOUT_HOME="$TMP/rollout-home"
"$REAL_PYTHON" - "$ROLLOUT_HOME/.codex/sessions/2026/09/16" <<'PY'
import json, os, sys
day = sys.argv[1]
os.makedirs(day)
for sid, cwd in (('codex-win-rollout', 'D:\\Proj\\Codex'), ('codex-posix-case', '/tmp/Proj')):
    meta = {'type': 'session_meta', 'payload': {'id': sid, 'cwd': cwd}}
    with open(os.path.join(day, f'rollout-{sid}.jsonl'), 'w') as f:
        f.write(json.dumps(meta) + '\n')
PY
assert_codex_ids "codex rollouts match a \\\\?\\ cwd" \
  '[["codex-win-rollout",null]]' "$ROLLOUT_HOME" '\\?\d:\proj\codex'
assert_codex_ids "codex keeps POSIX cwd matching exact" \
  '[]' "$ROLLOUT_HOME" '/tmp/proj'

if [ "$FAILURES" -ne 0 ]; then
  printf '%d failure(s)\n' "$FAILURES"
  exit 1
fi
