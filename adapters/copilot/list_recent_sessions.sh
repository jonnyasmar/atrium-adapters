#!/usr/bin/env bash
set -euo pipefail
export ATRIUM_COPILOT_METHOD=list_recent_sessions
bash "${BASH_SOURCE[0]%/*}/run-python.sh" "${BASH_SOURCE[0]%/*}/sessions.py" list "${1:?Usage: list_recent_sessions.sh <cwd>}" || printf '{"sessions":[]}\n'
