#!/usr/bin/env bash
set -euo pipefail

# install.assert.sh — Post-install assertions for the goose adapter.
# Verifies the Goose Open Plugins hook plugin (hooks/hooks.json spec:
# https://open-plugins.com/agent-builders/components/hooks) was written
# correctly: hooks.json wires every event Goose 1.50.0 dispatches to a plugin
# (SessionStart/SessionEnd/UserPromptSubmit/Stop plus the restored
# PreToolUse/PostToolUse/PostToolUseFailure) at the committed goose-hook.sh,
# which normalizes the payload and relays it through `atrium hook emit
# --pane-id` so the event is stored against the originating pane. Also checks
# that a global absolute GOOSE_PATH_ROOT redirects the plugin install to
# Goose's rooted plugin dir.

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_SH="${ADAPTER_DIR}/hooks.sh"
HOOKS_JSON="${HOME}/.agents/plugins/atrium-goose/hooks/hooks.json"
HOOK_SCRIPT="${ADAPTER_DIR}/goose-hook.sh"
NORMALIZER="${ADAPTER_DIR}/normalize-hook-payload.sh"

if [[ ! -f "$HOOKS_JSON" ]]; then
  echo "install.assert: $HOOKS_JSON does not exist" >&2
  exit 1
fi

# native Goose event : "<normalizer-event> <atrium-event>"
check_wired() {
  local native="$1" args="$2"
  if ! jq -e --arg n "$native" --arg a " ${args}\$" \
       '.hooks[$n][0].hooks[0].command | contains("${ATRIUM_DATA_DIR:-$HOME/.atrium}/adapters/goose/goose-hook.sh") and test($a)' \
       "$HOOKS_JSON" >/dev/null 2>&1; then
    echo "install.assert: $HOOKS_JSON missing $native -> goose-hook.sh $args" >&2
    exit 1
  fi
}

check_wired SessionStart       "session-start session-start"
check_wired SessionEnd         "session-end session-end"
check_wired UserPromptSubmit   "user-prompt-submit user-prompt-submit"
check_wired PreToolUse         "pre-tool-use pre-tool-use"
check_wired PostToolUse        "post-tool-use post-tool-use"
check_wired PostToolUseFailure "post-tool-use-failure post-tool-use"
check_wired Stop               "stop stop"

for f in "$HOOK_SCRIPT" "$NORMALIZER"; do
  if [[ ! -x "$f" ]]; then
    echo "install.assert: $f missing or not executable" >&2
    exit 1
  fi
done

# The relay must emit through the atrium CLI with the pane id, so the event is
# stored against the originating pane (not dropped as pane "unknown").
if ! grep -q 'hook emit' "$HOOK_SCRIPT"; then
  echo "install.assert: $HOOK_SCRIPT does not emit via 'atrium hook emit'" >&2
  exit 1
fi

if ! grep -q -- '--pane-id "\$ATRIUM_PANE_ID"' "$HOOK_SCRIPT"; then
  echo "install.assert: $HOOK_SCRIPT does not pass --pane-id \"\$ATRIUM_PANE_ID\"" >&2
  exit 1
fi

# It must stay inert outside an atrium pane and inside a chat pane.
if ! grep -q 'ATRIUM_PANE_ID:-' "$HOOK_SCRIPT" || ! grep -q 'ATRIUM_CHAT_SDK_HOOKS:-' "$HOOK_SCRIPT"; then
  echo "install.assert: $HOOK_SCRIPT missing ATRIUM_PANE_ID / ATRIUM_CHAT_SDK_HOOKS guards" >&2
  exit 1
fi

# A global absolute GOOSE_PATH_ROOT must redirect the plugin install to Goose's
# rooted plugin dir ($ROOT/.agents/plugins); a relative value must be ignored.
rooted="$(mktemp -d)"
trap 'rm -rf "$rooted"' EXIT
GOOSE_PATH_ROOT="$rooted" bash "$HOOKS_SH" install >/dev/null
if [[ ! -f "${rooted}/.agents/plugins/atrium-goose/hooks/hooks.json" ]]; then
  echo "install.assert: absolute GOOSE_PATH_ROOT did not redirect the plugin install" >&2
  exit 1
fi
GOOSE_PATH_ROOT="$rooted" bash "$HOOKS_SH" uninstall >/dev/null
if GOOSE_PATH_ROOT="relative/bad" bash "$HOOKS_SH" status | grep -q '"installed": false'; then
  echo "install.assert: relative GOOSE_PATH_ROOT should fall back to \$HOME plugin root" >&2
  exit 1
fi

exit 0
