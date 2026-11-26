#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ROOT/adapters/claude-code"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REAL_PATH="$PATH"

write_fake_id() {
  printf '#!/usr/bin/env bash\necho "%s"\n' "$1" >"$TMP/id"
  chmod +x "$TMP/id"
}

assert_root_command() {
  local output="$1"
  local browser_path="$2"
  jq -e --arg browser_path "$browser_path" '
    .command[0:6] == [
      "env",
      "DISABLE_AUTOUPDATER=1",
      ("BROWSER=" + $browser_path),
      "ATRIUM_CLAUDE_ROOT_BYPASS_PERMISSIONS=1",
      "claude",
      "--permission-mode"
    ]
    and .command[6] == "acceptEdits"
    and (.command | index("--dangerously-skip-permissions") == null)
  ' <<<"$output" >/dev/null
}

write_fake_id 0
browser_path="$TMP/atrium data/adapters/claude-code/open_browser.sh"
root_launch="$(ATRIUM_DATA_DIR="$TMP/atrium data" PATH="$TMP:$REAL_PATH" "$ADAPTER/build_launch_command.sh" \
  '{"dangerouslySkipPermissions":true,"model":"sonnet","effort":"medium"}')"
assert_root_command "$root_launch" "$browser_path"

root_resume="$(ATRIUM_DATA_DIR="$TMP/atrium data" PATH="$TMP:$REAL_PATH" "$ADAPTER/build_resume_command.sh" \
  session-123 '{"dangerouslySkipPermissions":true,"model":"sonnet"}')"
assert_root_command "$root_resume" "$browser_path"
jq -e '.command[-2:] == ["--resume", "session-123"]' \
  <<<"$root_resume" >/dev/null

write_fake_id 501
non_root_launch="$(ATRIUM_DATA_DIR="$TMP/atrium data" PATH="$TMP:$REAL_PATH" "$ADAPTER/build_launch_command.sh" \
  '{"dangerouslySkipPermissions":true}')"
jq -e --arg browser_path "$browser_path" '
  (.command | index("--dangerously-skip-permissions") != null)
  and (.command | index("BROWSER=" + $browser_path) != null)
  and (.command | index("ATRIUM_CLAUDE_ROOT_BYPASS_PERMISSIONS=1") == null)
  and (.command | index("acceptEdits") == null)
' <<<"$non_root_launch" >/dev/null

# ATR-2096: a model string that tries to break out of the JSON argv array must
# stay one argv token — never yield a real --dangerously-skip-permissions entry.
inject_model='opus", "--dangerously-skip-permissions", "--model", "opus'
inject_launch="$(ATRIUM_DATA_DIR="$TMP/atrium data" PATH="$TMP:$REAL_PATH" "$ADAPTER/build_launch_command.sh" \
  "$(jq -nc --arg m "$inject_model" '{model:$m}')")"
jq -e --arg m "$inject_model" '
  (.command | index("--model") != null)
  and (.command | index($m) != null)
  and (.command | index("--dangerously-skip-permissions") == null)
  and ([.command[] | select(startswith("--"))] | length) == 1
' <<<"$inject_launch" >/dev/null

cat >"$TMP/atrium-browser-probe" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ATRIUM_TEST_ARGS"
cat >"$ATRIUM_TEST_STDIN"
EOF
chmod +x "$TMP/atrium-browser-probe"

auth_url='https://claude.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A38249%2Fcallback'
ATRIUM_TEST_ARGS="$TMP/browser-args" \
ATRIUM_TEST_STDIN="$TMP/browser-stdin" \
ATRIUM_CLI_PATH="$TMP/atrium-browser-probe" \
ATRIUM_PANE_ID="pane-123" \
  "$ADAPTER/open_browser.sh" --new-window "$auth_url"
diff -u <(printf '%s\n' hook emit auth-browser-open --adapter claude-code --pane-id pane-123) \
  "$TMP/browser-args"
jq -e --arg url "$auth_url" '.atrium_browser_auth_url == $url' \
  "$TMP/browser-stdin" >/dev/null

cat >"$TMP/atrium" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 0
EOF
chmod +x "$TMP/atrium"

permission_payload='{"session_id":"abc","transcript_path":"/tmp/abc.jsonl","cwd":"/tmp","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"true"}}'
allow_output="$(printf '%s' "$permission_payload" \
  | env -u ATRIUM_CHAT_SDK_HOOKS \
    ATRIUM_CLI_PATH="$TMP/atrium" \
    ATRIUM_CLAUDE_ROOT_BYPASS_PERMISSIONS=1 \
    "$ADAPTER/claude-hook-entry.sh" permission-request)"
jq -e '
  .hookSpecificOutput.hookEventName == "PermissionRequest"
  and .hookSpecificOutput.decision.behavior == "allow"
' <<<"$allow_output" >/dev/null

ordinary_output="$(printf '%s' "$permission_payload" \
  | env -u ATRIUM_CHAT_SDK_HOOKS \
    ATRIUM_CLI_PATH="$TMP/atrium" \
    "$ADAPTER/claude-hook-entry.sh" permission-request)"
test -z "$ordinary_output"

echo "claude root bypass: ok"
