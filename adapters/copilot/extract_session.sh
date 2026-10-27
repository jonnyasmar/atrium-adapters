#!/usr/bin/env bash
set -euo pipefail
export ATRIUM_COPILOT_METHOD=extract_session
exec bash "${BASH_SOURCE[0]%/*}/run-python.sh" "${BASH_SOURCE[0]%/*}/sessions.py" extract "$@"
