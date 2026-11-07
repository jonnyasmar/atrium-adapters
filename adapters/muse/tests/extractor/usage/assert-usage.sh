#!/usr/bin/env bash
set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE_DIR="$ADAPTER_DIR/tests/extractor/usage/input"
OUTPUT="$(ATRIUM_TEST_MUSE_SESSION_ROOT="$FIXTURE_DIR" bash "$ADAPTER_DIR/extract_session.sh" \
  --session-id muse-synthetic --cwd /synthetic/muse --depth standard)"

if printf '%s\n' "$OUTPUT" | python3 -c 'import json,sys; assert all(json.loads(line).get("type") != "usage" for line in sys.stdin if line.strip())'; then
  exit 0
fi
echo "muse extractor emitted a usage event without durable per-request usage evidence" >&2
exit 1
