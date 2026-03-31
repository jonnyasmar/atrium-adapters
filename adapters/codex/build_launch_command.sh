#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Codex.
# Takes $1 = JSON flags
# Output: {"command": ["codex"]} or {"command": ["codex", "--dangerously-bypass-approvals-and-sandbox"]}

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
  echo '{"command": ["codex", "--dangerously-bypass-approvals-and-sandbox"]}'
else
  echo '{"command": ["codex"]}'
fi
exit 0
