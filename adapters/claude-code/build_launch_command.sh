#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Claude Code.
# Takes $1 = JSON flags
# Output: {"command": ["claude"]} or {"command": ["claude", "--dangerously-skip-permissions"]}

FLAGS="${1:-"{}"}"

# Parse dangerouslySkipPermissions from flags JSON
SKIP_PERMISSIONS=false
if command -v jq &>/dev/null; then
  SKIP_PERMISSIONS="$(echo "$FLAGS" | jq -r '.dangerouslySkipPermissions // .dangerous_skip_permissions // false' 2>/dev/null)" || SKIP_PERMISSIONS=false
else
  # Fallback: grep for the key
  if echo "$FLAGS" | grep -qE '"dangerouslySkipPermissions"\s*:\s*true|"dangerous_skip_permissions"\s*:\s*true'; then
    SKIP_PERMISSIONS=true
  fi
fi

if [ "$SKIP_PERMISSIONS" = "true" ]; then
  echo '{"command": ["claude", "--dangerously-skip-permissions"]}'
else
  echo '{"command": ["claude"]}'
fi
exit 0
