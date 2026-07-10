# Grok Extractor Fixture

Synthetic `chat_history.jsonl` for CI testing of `extract_session.sh` / `extract_session.py`.

- `fixture-session.jsonl` — Grok Build-shaped transcript: system + synthetic user_info + real user_query + reasoning + assistant with tool_calls (read_file + run_terminal_command) + tool_results + final assistant prose.
- `fixture-summary.json` — optional summary timestamps/title (production `summary.json`).
- `fixture-session-id.txt` — Session ID the fixture represents.
- `assert.sh` — Smoke-test runner: depth filtering, user_query unwrap, reasoning drop, deep allowlist, canonical-schema conformance, exit-code contract.

Invoke via `ATRIUM_TEST_TRANSCRIPT_ROOT="$PWD" ../extract_session.sh --session-id $(cat fixture-session-id.txt) --cwd /tmp --depth standard` from this directory (or let `validate-adapter.sh` / `assert.sh` drive it).
