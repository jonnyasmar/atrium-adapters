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
messages = [json.loads(value) for (value,) in connection.execute("SELECT value FROM messages ORDER BY key")]
assert len(messages) == 2 and all("usage" not in message for message in messages)
assert open(sys.argv[3], encoding="utf-8").read() == ""
PY
