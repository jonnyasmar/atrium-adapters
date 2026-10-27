#!/usr/bin/env bash
set -uo pipefail
[ -n "${ATRIUM_PANE_ID:-}" ] || exit 0
[ "${ATRIUM_CHAT_SDK_HOOKS:-}" != 1 ] || exit 0
export ATRIUM_DATA_DIR="${ATRIUM_DATA_DIR:-${2:-}}"
export ATRIUM_CLI_PATH="${ATRIUM_CLI_PATH:-${3:-atrium}}"
adapter_dir="${ATRIUM_DATA_DIR}/adapters/copilot"
[ -f "$adapter_dir/hooks.py" ] || exit 0
bash "$adapter_dir/run-python.sh" "$adapter_dir/hooks.py" emit "${1:-}" || printf '{}\n'
# Copilot's preToolUse is fail-closed on a nonzero exit. An unavailable
# atrium bridge must never deny a tool or grant additional permissions.
exit 0
