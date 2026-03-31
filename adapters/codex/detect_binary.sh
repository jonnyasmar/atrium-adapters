#!/usr/bin/env bash
set -euo pipefail

# detect_binary.sh — Detect the codex CLI binary location.
# Output: {"path": "/path/to/codex"} or {"path": null}

# 1. Check PATH via which
if binary_path="$(which codex 2>/dev/null)"; then
  echo "{\"path\": \"${binary_path}\"}"
  exit 0
fi

# 2. Check well-known paths
well_known_paths=(
  "${HOME}/.npm-global/bin/codex"
  "${HOME}/.npm/bin/codex"
  "/usr/local/bin/codex"
  "${HOME}/.local/bin/codex"
  "/opt/homebrew/bin/codex"
  "${HOME}/.cargo/bin/codex"
  "${HOME}/.nvm/current/bin/codex"
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
