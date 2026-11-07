#!/usr/bin/env bash
set -euo pipefail
ADAPTER_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
python3 "$ADAPTER_DIR/../shared/extract_session_usage_test.py" "$ADAPTER_DIR"
exec python3 "$ADAPTER_DIR/tests/extractor/usage/test_fork_prefix.py"
