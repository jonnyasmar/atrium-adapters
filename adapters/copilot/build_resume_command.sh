#!/usr/bin/env bash
set -euo pipefail
SESSION_ID="${1:?Usage: build_resume_command.sh <session_id> [flags_json]}"
exec bash "${BASH_SOURCE[0]%/*}/build_launch_command.sh" "${2:-"{}"}" "$SESSION_ID"
