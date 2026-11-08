#!/usr/bin/env bash
set -euo pipefail
ADAPTER_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 - "$ADAPTER_DIR/adapter.json" "$FIXTURE_DIR/fixture.sql" "$FIXTURE_DIR/expected-usage.jsonl" <<'PY'
import json, sqlite3, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert "usage" not in manifest["sessionExtractor"]
connection = sqlite3.connect(":memory:")
connection.executescript(open(sys.argv[2], encoding="utf-8").read())
assert connection.execute("SELECT api_call_count FROM sessions").fetchone() == (7,)
assert connection.execute("SELECT token_count FROM messages").fetchone() == (64,)
assert connection.execute("SELECT COUNT(*) FROM session_model_usage").fetchone() == (1,)
assert open(sys.argv[3], encoding="utf-8").read() == ""
PY
