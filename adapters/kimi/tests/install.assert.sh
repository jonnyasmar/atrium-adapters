#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${KIMI_CODE_HOME:-$HOME/.kimi-code}/config.toml"
ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ -f "$CONFIG_FILE" ]] || {
  echo "install.assert: missing $CONFIG_FILE" >&2
  exit 1
}

managed="$(awk '
  $0 == "# >>> atrium kimi hooks >>>" { active = 1; next }
  $0 == "# <<< atrium kimi hooks <<<" { active = 0 }
  active { print }
' "$CONFIG_FILE")"

[[ "$(printf '%s\n' "$managed" | grep -c '^\[\[hooks\]\]$')" -eq 16 ]] || {
  echo "install.assert: expected 16 managed Kimi hooks" >&2
  exit 1
}

for event in \
  SessionStart SessionEnd PreToolUse PostToolUse PostToolUseFailure \
  UserPromptSubmit Stop StopFailure Interrupt PermissionRequest \
  PermissionResult SubagentStart SubagentStop PreCompact PostCompact Notification; do
  grep -Fq "event = \"$event\"" <<<"$managed" || {
    echo "install.assert: missing $event" >&2
    exit 1
  }
done

grep -Fq 'ATRIUM_HOOK_MARKER=atrium-runtime-hook' <<<"$managed"
grep -Fq "$ADAPTER_DIR/kimi-hook.sh" <<<"$managed"
! grep -Fq 'matcher =' <<<"$managed"

jq -e '
  .chatTransport.kind == "acp"
  and .chatTransport.args == ["acp"]
  and .chatTransport.capabilities.resume == true
  and .chatTransport.capabilities.permissionCallback == true
  and .chatTransport.capabilities.imageInput == true
  and .inputRequestTools == ["AskUserQuestion"]
' "$ADAPTER_DIR/adapter.json" >/dev/null

launch="$("$ADAPTER_DIR/build_launch_command.sh" \
  '{"permissionMode":"auto","plan":true,"model":"kimi-code/k3","effort":"high","extraArgs":"--agent default"}')"
jq -e '.command == ["env","KIMI_MODEL_THINKING_EFFORT=high","kimi","--auto","--plan","--model","kimi-code/k3","--agent","default"]' \
  <<<"$launch" >/dev/null

resume="$("$ADAPTER_DIR/build_resume_command.sh" \
  '01234567-89ab-cdef-0123-456789abcdef' '{"yolo":true,"effort":"max"}')"
jq -e '.command == ["env","KIMI_MODEL_THINKING_EFFORT=max","kimi","--session","01234567-89ab-cdef-0123-456789abcdef","--yolo"]' \
  <<<"$resume" >/dev/null

jq -e '
  .options
  | (map(select(.key == "yolo" and .type == "toggle" and (.label | contains("👮")))) | length == 1)
    and (map(select(.key == "model" and .type == "select" and (.choices | length == 3))) | length == 1)
    and (map(select(.key == "effort" and .choices == ["low", "high", "max"])) | length == 1)
' "$ADAPTER_DIR/launcher_options.json" >/dev/null
