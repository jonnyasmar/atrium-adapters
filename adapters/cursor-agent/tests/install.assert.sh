#!/usr/bin/env bash
set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

jq -e '
  .chatTransport.kind == "acp"
  and .chatTransport.args == ["acp"]
  and (.chatTransport.extraArgs | index("--disable-auto-update") != null)
  and .chatTransport.capabilities.resume == true
  and .chatTransport.capabilities.planMode == true
  and .chatTransport.capabilities.permissionCallback == true
  and .chatTransport.capabilities.imageInput == true
  and .chatTransport.capabilities.setModel == true
  and .methods.check_update.script == "check_update.sh"
  and .icon == "icon.svg"
  and .skillInstallPath == "~/.cursor/skills/atrium/SKILL.md"
  and .version == "0.5.1"
' "$ADAPTER_DIR/adapter.json" >/dev/null

[[ -f "$ADAPTER_DIR/icon.svg" ]] || {
  echo "install.assert: missing icon.svg" >&2
  exit 1
}
[[ -x "$ADAPTER_DIR/check_update.sh" ]] || {
  echo "install.assert: check_update.sh not executable" >&2
  exit 1
}

launch_yolo="$("$ADAPTER_DIR/build_launch_command.sh" \
  '{"yolo":true,"model":"claude-opus-5-high","trust":true}')"
jq -e '
  .command[0] == "cursor-agent"
  and (.command | index("--disable-auto-update") != null)
  and (.command | index("--force") != null)
  and (.command | index("--trust") != null)
  and (.command | index("claude-opus-5-high") != null)
' <<<"$launch_yolo" >/dev/null

launch_auto="$("$ADAPTER_DIR/build_launch_command.sh" '{"autoReview":true}')"
jq -e '
  (.command | index("--auto-review") != null)
  and (.command | index("--force") == null)
' <<<"$launch_auto" >/dev/null

# yolo wins over auto-review
launch_both="$("$ADAPTER_DIR/build_launch_command.sh" '{"yolo":true,"autoReview":true}')"
jq -e '
  (.command | index("--force") != null)
  and (.command | index("--auto-review") == null)
' <<<"$launch_both" >/dev/null

launch_plan="$("$ADAPTER_DIR/build_launch_command.sh" '{"plan":true,"sandbox":"enabled"}')"
jq -e '
  (.command | index("--plan") != null)
  and (.command | index("--sandbox") != null)
  and (.command | index("enabled") != null)
' <<<"$launch_plan" >/dev/null

resume="$("$ADAPTER_DIR/build_resume_command.sh" \
  'chat-abc' '{"yolo":true,"plan":true,"model":"composer-2.5","extraArgs":"--foo bar"}')"
jq -e '
  .command[0] == "cursor-agent"
  and (.command | index("--disable-auto-update") != null)
  and (.command | index("--force") != null)
  and (.command | index("--plan") != null)
  and (.command | index("--model") != null)
  and (.command | index("--resume") != null)
  and (.command[-1] == "chat-abc")
' <<<"$resume" >/dev/null

jq -e '
  .options
  | (map(select(.key == "yolo" and .type == "toggle" and (.label | contains("👮")))) | length == 1)
    and (map(select(.key == "autoReview" and .type == "toggle")) | length == 1)
    and (map(select(.key == "plan" and .type == "toggle")) | length == 1)
    and (map(select(.key == "model" and .type == "select" and (.choices | length >= 20))) | length == 1)
    and ([.[] | select(.key == "model") | .choices[].value] | index("claude-opus-5-high") != null)
    and ([.[] | select(.key == "model") | .choices[].value] | index("grok-4.3") == null)
    and ([.[] | select(.key == "model") | .choices[].value] | index("cursor-grok-4.6-high") != null)
    and ([.[] | select(.key == "model") | .choices[].value] | index("cursor-grok-4.5-high") != null)
' "$ADAPTER_DIR/launcher_options.json" >/dev/null

echo "install.assert: cursor-agent ok"
