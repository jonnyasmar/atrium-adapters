# codex Extractor Fixture

Synthetic transcript for CI testing of `extract_session.sh` (and Python companion if applicable).

- `fixture-session.*` — Native-format synthetic transcript (1 user prompt + 1 assistant text + 1 tool_use + 1 tool_result + 1 final assistant text).
- `fixture-session-id.txt` — Session ID the fixture represents.
- `assert.sh` — Smoke-test runner: verifies depth filtering (quick=2, standard>=4, deep>=5), canonical-schema conformance via `jsonschema`, exit-code contract, and (where applicable) Python-stdlib-only constraint.

Invoke via: `ATRIUM_TEST_TRANSCRIPT_ROOT="$PWD" ./extract_session.sh --session-id $(cat fixture-session-id.txt) --cwd /tmp --depth standard`.
