#!/usr/bin/env bash
set -euo pipefail

# detect_binary.sh — Detect the claude CLI binary location.
# Output: {"path": "/path/to/claude"} or {"path": null}

# 1. Check PATH via which
if binary_path="$(which claude 2>/dev/null)"; then
  echo "{\"path\": \"${binary_path}\"}"
  exit 0
fi

# 2. Check well-known paths
well_known_paths=(
  "${HOME}/.npm-global/bin/claude"
  "${HOME}/.npm/bin/claude"
  "/usr/local/bin/claude"
  "${HOME}/.local/bin/claude"
  "/opt/homebrew/bin/claude"
  "${HOME}/.cargo/bin/claude"
  "${HOME}/.nvm/current/bin/claude"
)

for candidate in "${well_known_paths[@]}"; do
  if [ -x "$candidate" ]; then
    echo "{\"path\": \"${candidate}\"}"
    exit 0
  fi
done

# Not found
echo '{"path": null}'
exit 0
