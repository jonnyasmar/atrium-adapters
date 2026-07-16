#!/usr/bin/env bash
# assert.sh — claude-hook-entry must refuse Cursor-shaped invocations
# and accept real Claude Code ones without calling atrium (we stub CLI).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENTRY="$ROOT/claude-hook-entry.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub atrium so a real emit never hits a socket; record whether we were called.
STUB_CLI="$TMP/atrium"
cat >"$STUB_CLI" <<'EOF'
#!/usr/bin/env bash
echo "called:$*" >>"${ATRIUM_STUB_LOG:?}"
# consume stdin
cat >/dev/null
exit 0
EOF
chmod +x "$STUB_CLI" "$ENTRY"

export ATRIUM_CLI_PATH="$STUB_CLI"
export ATRIUM_PANE_ID="test-pane"
unset CURSOR_INVOKED_AS || true

pass=0
fail=0
check() {
  local name="$1" expect_called="$2"
  shift 2
  : >"$TMP/log"
  ATRIUM_STUB_LOG="$TMP/log" "$@"
  local called=0
  [ -s "$TMP/log" ] && called=1
  if [ "$called" -eq "$expect_called" ]; then
    echo "ok  - $name"
    pass=$((pass + 1))
  else
    echo "FAIL - $name (called=$called expect=$expect_called log=$(cat "$TMP/log" 2>/dev/null || true))"
    fail=$((fail + 1))
  fi
}

# 1. Real Claude SessionStart → emit
check "claude session-start emits" 1 \
  env -u CURSOR_INVOKED_AS bash "$ENTRY" session-start <<'JSON'
{"session_id":"abc","transcript_path":"/Users/x/.claude/projects/foo/abc.jsonl","cwd":"/tmp"}
JSON

# 2. Cursor env → no emit
check "CURSOR_INVOKED_AS suppresses emit" 0 \
  env CURSOR_INVOKED_AS=cursor-agent bash "$ENTRY" session-start <<'JSON'
{"session_id":"abc","transcript_path":"/Users/x/.claude/projects/foo/abc.jsonl","cwd":"/tmp"}
JSON

# 3. Cursor-shaped payload (no env) → no emit
check "cursor payload shape suppresses emit" 0 \
  env -u CURSOR_INVOKED_AS bash "$ENTRY" session-start <<'JSON'
{"conversation_id":"7029c2cd","generation_id":"7029c2cd","model":"composer-2.5-fast","is_background_agent":false,"session_id":"7029c2cd"}
JSON

# 4. Cursor tool payload → no emit
check "cursor pre-tool-use payload suppresses emit" 0 \
  env -u CURSOR_INVOKED_AS bash "$ENTRY" pre-tool-use <<'JSON'
{"conversation_id":"7029c2cd","generation_id":"5b48","model":"composer-2.5","tool_name":"Shell","tool_input":{"command":"ls"},"session_id":"7029c2cd"}
JSON

# 5. Claude tool payload → emit
check "claude pre-tool-use emits" 1 \
  env -u CURSOR_INVOKED_AS bash "$ENTRY" pre-tool-use <<'JSON'
{"session_id":"abc","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}
JSON

# 6. Chat sidecar SDK hooks own atrium dispatch → no shell dual-fire
check "ATRIUM_CHAT_SDK_HOOKS suppresses emit" 0 \
  env -u CURSOR_INVOKED_AS ATRIUM_CHAT_SDK_HOOKS=1 bash "$ENTRY" session-start <<'JSON'
{"session_id":"abc","transcript_path":"/Users/x/.claude/projects/foo/abc.jsonl","cwd":"/tmp"}
JSON

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
