# Claude Code Extractor Fixture

Synthetic transcript for CI testing of `extract_session.sh` / `extract_session.py`.

- `fixture-session.jsonl` — Anthropic-shaped 4-line transcript: 1 user prompt + 1 assistant text + 1 tool_use (Bash) + 1 tool_result + 1 final assistant text.
- `fixture-session-id.txt` — Session ID the fixture represents.
- `assert.sh` — Smoke-test runner: verifies depth filtering (quick=2 events, standard>=4, deep>=5), canonical-schema conformance via `jsonschema`, exit-code contract, and Python-stdlib-only constraint.

Invoke via `ATRIUM_TEST_TRANSCRIPT_ROOT="$PWD" ./extract_session.sh --session-id $(cat fixture-session-id.txt) --cwd /tmp --depth standard`.
