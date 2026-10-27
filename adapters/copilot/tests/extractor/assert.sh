#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
export ATRIUM_TEST_TRANSCRIPT_ROOT="$HERE"
"$HERE/../../extract_session.sh" --session-id copilot-fixture --cwd /work/proj --depth deep \
  | jq -es 'length == 6 and .[0].adapter == "copilot" and .[-1].event_count == 6 and .[3].tool == "edit"' >/dev/null
