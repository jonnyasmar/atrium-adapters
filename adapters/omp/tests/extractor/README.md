# omp Extractor Fixture

Synthetic transcript for CI testing of `extract_session.sh`.

- `fixture-session.jsonl` — Native omp (session format v3) synthetic transcript: title record + session header + 1 user prompt + 1 assistant text with a `toolCall` block + 1 `toolResult` message + 1 final assistant text.
- `fixture-session-id.txt` — Session ID the fixture represents.
- `assert.sh` — Smoke-test runner: verifies depth filtering (quick=2, standard>=4, deep>=5), canonical-schema conformance via `jsonschema`, exit-code contract, and shebang/setopt constraints.

Invoke via: `ATRIUM_TEST_TRANSCRIPT_ROOT="$PWD" ../../extract_session.sh --session-id $(cat fixture-session-id.txt) --cwd /tmp --depth standard`.
