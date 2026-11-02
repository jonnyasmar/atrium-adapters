#!/usr/bin/env bash
set -euo pipefail
jq -e '.version == 1 and (.hooks.sessionStart | length == 1) and (.hooks.userPromptTransformed | length == 1) and (.hooks.preToolUse[0].args == [(env.COPILOT_HOME // (env.HOME + "/.copilot")) + "/atrium-hook.sh", "preToolUse"])' \
  "${COPILOT_HOME:-$HOME/.copilot}/hooks/atrium.json" >/dev/null
test -x "${COPILOT_HOME:-$HOME/.copilot}/atrium-hook.sh"
