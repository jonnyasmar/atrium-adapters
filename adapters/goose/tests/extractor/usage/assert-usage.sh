#!/usr/bin/env bash
set -euo pipefail
FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$FIXTURE_DIR/test_usage.py"
python3 "$FIXTURE_DIR/test_wal.py"
python3 "$FIXTURE_DIR/test_streaming.py"
