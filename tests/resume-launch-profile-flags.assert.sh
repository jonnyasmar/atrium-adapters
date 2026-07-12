#!/usr/bin/env bash
set -euo pipefail

# Regression check for launcher resume paths. These scripts receive the
# LaunchProfile-derived flags bag from atrium; resume must preserve the same
# model/effort/provider/extra-args knobs that fresh launch supports.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_ID="sess-123"
FAILURES=0

assert_command() {
  local adapter="$1"
  local flags="$2"
  local expected_json="$3"
  local script="${ROOT}/adapters/${adapter}/build_resume_command.sh"

  local actual
  actual="$(bash "$script" "$SESSION_ID" "$flags")"

  local actual_command expected_command
  actual_command="$(echo "$actual" | jq -c '.command')"
  expected_command="$(echo "$expected_json" | jq -c '.')"

  if [[ "$actual_command" == "$expected_command" ]]; then
    printf '[PASS] %s resume preserves launch-profile flags\n' "$adapter"
  else
    printf '[FAIL] %s resume command mismatch\n' "$adapter"
    printf '  expected: %s\n' "$expected_command"
    printf '  actual:   %s\n' "$actual_command"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_command \
  "codex" \
  '{"dangerouslySkipPermissions":true,"model":"gpt-5.3-codex","effort":"high","extraArgs":"--search --sandbox workspace-write"}' \
  '["codex","--dangerously-bypass-approvals-and-sandbox","-m","gpt-5.3-codex","-c","model_reasoning_effort=\"high\"","--search","--sandbox","workspace-write","resume","sess-123"]'

assert_command \
  "cursor-agent" \
  '{"yolo":true,"plan":true,"model":"cursor-model","extraArgs":"--foo bar"}' \
  '["cursor-agent","--force","--plan","--model","cursor-model","--foo","bar","--resume","sess-123"]'

assert_command \
  "antigravity" \
  '{"dangerouslySkipPermissions":true,"sandbox":true,"model":"ag-model","extraArgs":"--foo bar"}' \
  '["agy","--conversation","sess-123","--dangerously-skip-permissions","--sandbox","--model","ag-model","--foo","bar"]'

# Grok launches via grok-with-atrium-rules.sh (rules injected inside the
# wrapper — never as multi-line argv, which breaks atrium's unquoted
# cmd.join(" ") PTY typing). Assert wrapper + flag preservation.
{
  adapter="grok"
  flags='{"alwaysApprove":true,"model":"grok-build","effort":"max","extraArgs":"--cwd /tmp"}'
  script="${ROOT}/adapters/${adapter}/build_resume_command.sh"
  wrapper="${ROOT}/adapters/${adapter}/grok-with-atrium-rules.sh"
  actual="$(bash "$script" "$SESSION_ID" "$flags")"
  cmd="$(echo "$actual" | jq -c '.command')"
  expected="$(jq -nc \
    --arg w "$(cd "$(dirname "$wrapper")" && pwd)/grok-with-atrium-rules.sh" \
    '[$w,"--always-approve","--model","grok-build","--reasoning-effort","max","--cwd","/tmp","-r","sess-123"]')"
  # Normalize wrapper path from actual (script resolves via its own SCRIPT_DIR).
  actual_norm="$(echo "$actual" | jq -c --arg w "$(cd "$(dirname "$wrapper")" && pwd)/grok-with-atrium-rules.sh" '
    .command[0] = $w | .command
  ')"
  if [[ "$actual_norm" == "$expected" ]] \
    && [[ "$(echo "$actual" | jq -r '.command[0]')" == *"/grok-with-atrium-rules.sh" ]] \
    && ! echo "$actual" | jq -e '.command | index("--rules")' >/dev/null; then
    printf '[PASS] %s resume preserves launch-profile flags via rules wrapper\n' "$adapter"
  else
    printf '[FAIL] %s resume command mismatch (wrapper+flags)\n' "$adapter"
    printf '  expected: %s\n' "$expected"
    printf '  actual:   %s\n' "$cmd"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_command \
  "hermes" \
  '{"dangerouslySkipPermissions":true,"model":"anthropic/claude","provider":"openrouter","extraArgs":"--max-turns 3"}' \
  '["hermes","chat","--yolo","-m","anthropic/claude","--provider","openrouter","--max-turns","3","--resume","sess-123"]'

if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi
