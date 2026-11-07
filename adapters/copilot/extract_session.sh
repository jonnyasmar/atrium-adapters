#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--usage" ]]; then
  shift
  exec bash "${BASH_SOURCE[0]%/*}/run-python.sh" "${BASH_SOURCE[0]%/*}/extract_session_usage.py" --usage "$@"
fi

export ATRIUM_COPILOT_METHOD=extract_session
exec bash "${BASH_SOURCE[0]%/*}/run-python.sh" "${BASH_SOURCE[0]%/*}/sessions.py" extract "$@"
