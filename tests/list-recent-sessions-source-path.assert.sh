#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_HOME="$(mktemp -d /tmp/atrium-list-sessions.XXXXXX)"
WORKSPACE="${FIXTURE_HOME}/workspace"
FAILURES=0

trap 'rm -rf "$FIXTURE_HOME"' EXIT

for dependency in jq perl python3 sqlite3; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf '[FAIL] missing test dependency: %s\n' "$dependency"
    exit 1
  fi
done

mkdir -p "$WORKSPACE"

assert_source_path() {
  local label="$1"
  local expected="$2"
  shift 2

  local output actual
  if ! output="$("$@")"; then
    printf '[FAIL] %s enumerator exited unsuccessfully\n' "$label"
    FAILURES=$((FAILURES + 1))
    return
  fi

  if ! actual="$(jq -er '.sessions[0].sourcePath' <<<"$output")"; then
    printf '[FAIL] %s did not emit sourcePath: %s\n' "$label" "$output"
    FAILURES=$((FAILURES + 1))
  elif [[ "$actual" != "$expected" ]]; then
    printf '[FAIL] %s sourcePath mismatch\n' "$label"
    printf '  expected: %s\n' "$expected"
    printf '  actual:   %s\n' "$actual"
    FAILURES=$((FAILURES + 1))
  elif [[ ! -f "$actual" ]]; then
    printf '[FAIL] %s sourcePath does not exist: %s\n' "$label" "$actual"
    FAILURES=$((FAILURES + 1))
  else
    printf '[PASS] %s emits its indexable source path\n' "$label"
  fi
}

CLAUDE_PROJECT="-${WORKSPACE#/}"
CLAUDE_PROJECT="${CLAUDE_PROJECT//\//-}"
CLAUDE_PROJECT="${CLAUDE_PROJECT//./-}"
CLAUDE_SOURCE="${FIXTURE_HOME}/.claude/projects/${CLAUDE_PROJECT}/claude-session.jsonl"
mkdir -p "$(dirname "$CLAUDE_SOURCE")"
printf '{"type":"user","sessionId":"claude-session","cwd":"%s","message":{"content":"hello"}}\n' \
  "$WORKSPACE" >"$CLAUDE_SOURCE"
assert_source_path \
  "claude-code" \
  "$CLAUDE_SOURCE" \
  env HOME="$FIXTURE_HOME" bash "$ROOT/adapters/claude-code/list_recent_sessions.sh" "$WORKSPACE"

CODEX_SOURCE="${FIXTURE_HOME}/.codex/sessions/2026/07/21/rollout-fixture.jsonl"
mkdir -p "$(dirname "$CODEX_SOURCE")"
printf '{"type":"session_meta","timestamp":"2026-07-21T12:00:00Z","payload":{"id":"codex-session","cwd":"%s","timestamp":"2026-07-21T12:00:00Z"}}\n' \
  "$WORKSPACE" >"$CODEX_SOURCE"
assert_source_path \
  "codex rollout" \
  "$CODEX_SOURCE" \
  env HOME="$FIXTURE_HOME" bash "$ROOT/adapters/codex/list_recent_sessions.sh" "$WORKSPACE"

CODEX_DB_HOME="${FIXTURE_HOME}/codex-db-home"
CODEX_DB="${CODEX_DB_HOME}/.codex/state_5.sqlite"
mkdir -p "$(dirname "$CODEX_DB")"
sqlite3 "$CODEX_DB" \
  "CREATE TABLE threads(id TEXT, cwd TEXT, title TEXT, updated_at INTEGER, first_user_message TEXT, archived INTEGER); INSERT INTO threads VALUES('codex-db-session', '${WORKSPACE}', 'fixture', 1784635200, '', 0);"
assert_source_path \
  "codex sqlite" \
  "$CODEX_DB" \
  env HOME="$CODEX_DB_HOME" bash "$ROOT/adapters/codex/list_recent_sessions.sh" "$WORKSPACE"

NO_JQ_BIN="${FIXTURE_HOME}/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
for dependency in bash perl sqlite3; do
  ln -s "$(command -v "$dependency")" "$NO_JQ_BIN/$dependency"
done
assert_source_path \
  "codex sqlite without jq" \
  "$CODEX_DB" \
  env HOME="$CODEX_DB_HOME" PATH="$NO_JQ_BIN" \
  bash "$ROOT/adapters/codex/list_recent_sessions.sh" "$WORKSPACE"

ANTIGRAVITY_ROOT="${FIXTURE_HOME}/.gemini/antigravity-cli"
ANTIGRAVITY_SOURCE="${ANTIGRAVITY_ROOT}/brain/agy-session/.system_generated/logs/transcript.jsonl"
mkdir -p "$(dirname "$ANTIGRAVITY_SOURCE")" "${ANTIGRAVITY_ROOT}/cache" "${ANTIGRAVITY_ROOT}/conversations"
jq -nc --arg cwd "$WORKSPACE" '{($cwd): "agy-session"}' \
  >"${ANTIGRAVITY_ROOT}/cache/last_conversations.json"
printf 'fixture' >"${ANTIGRAVITY_ROOT}/conversations/agy-session.pb"
printf '{"type":"USER_INPUT","content":"<USER_REQUEST>Hello</USER_REQUEST>"}\n' \
  >"$ANTIGRAVITY_SOURCE"
assert_source_path \
  "antigravity" \
  "$ANTIGRAVITY_SOURCE" \
  env HOME="$FIXTURE_HOME" bash "$ROOT/adapters/antigravity/list_recent_sessions.sh" "$WORKSPACE"

CURSOR_HASH="$(python3 -c 'import hashlib, os, sys; print(hashlib.md5(os.path.realpath(sys.argv[1]).encode()).hexdigest())' "$WORKSPACE")"
CURSOR_SOURCE="${FIXTURE_HOME}/.cursor/chats/${CURSOR_HASH}/cursor-session/store.db"
mkdir -p "$(dirname "$CURSOR_SOURCE")"
sqlite3 "$CURSOR_SOURCE" 'CREATE TABLE meta(key TEXT, value TEXT);'
assert_source_path \
  "cursor-agent" \
  "$CURSOR_SOURCE" \
  env HOME="$FIXTURE_HOME" bash "$ROOT/adapters/cursor-agent/list_recent_sessions.sh" "$WORKSPACE"

OPENCODE_PROJECT="${FIXTURE_HOME}/.local/share/opencode/project/project-fixture"
OPENCODE_SOURCE="${OPENCODE_PROJECT}/storage/session/info/opencode-session.json"
mkdir -p "$(dirname "$OPENCODE_SOURCE")"
jq -nc --arg path "$WORKSPACE" '{path: $path}' >"${OPENCODE_PROJECT}/project.json"
printf '{"id":"opencode-session","title":"fixture","time":{"updated":1784635200000}}\n' \
  >"$OPENCODE_SOURCE"
assert_source_path \
  "opencode" \
  "$OPENCODE_SOURCE" \
  env HOME="$FIXTURE_HOME" bash "$ROOT/adapters/opencode/list_recent_sessions.sh" "$WORKSPACE"

PI_DIR="${FIXTURE_HOME}/pi-sessions"
PI_SOURCE="${PI_DIR}/pi-session.jsonl"
mkdir -p "$PI_DIR"
printf '{"id":"pi-session","cwd":"%s"}\n{"role":"user","content":"hello"}\n' \
  "$WORKSPACE" >"$PI_SOURCE"
assert_source_path \
  "pi" \
  "$PI_SOURCE" \
  env HOME="$FIXTURE_HOME" PI_CODING_AGENT_SESSION_DIR="$PI_DIR" \
  bash "$ROOT/adapters/pi/list_recent_sessions.sh" "$WORKSPACE"

GROK_ENCODED="$(printf '%s' "$WORKSPACE" | perl -MURI::Escape -e 'print uri_escape(<STDIN>, "^A-Za-z0-9");')"
GROK_SESSION="${FIXTURE_HOME}/.grok/sessions/${GROK_ENCODED}/grok-session"
GROK_SOURCE="${GROK_SESSION}/chat_history.jsonl"
mkdir -p "$GROK_SESSION"
printf '{"id":"grok-session","cwd":"%s","generated_title":"fixture","updated_at":"2026-07-21T12:00:00Z"}\n' \
  "$WORKSPACE" >"${GROK_SESSION}/summary.json"
printf '{"role":"user","content":"hello"}\n' >"$GROK_SOURCE"
assert_source_path \
  "grok" \
  "$GROK_SOURCE" \
  env HOME="$FIXTURE_HOME" bash "$ROOT/adapters/grok/list_recent_sessions.sh" "$WORKSPACE"

HERMES_HOME_DIR="${FIXTURE_HOME}/hermes-home"
HERMES_SOURCE="${HERMES_HOME_DIR}/state.db"
mkdir -p "$HERMES_HOME_DIR"
sqlite3 "$HERMES_SOURCE" \
  "CREATE TABLE sessions(id TEXT, title TEXT, cwd TEXT, ended_at INTEGER, started_at INTEGER, source TEXT, archived INTEGER); INSERT INTO sessions VALUES('hermes-session', 'fixture', '${WORKSPACE}', 1784635200, 1784635100, 'cli', 0);"
assert_source_path \
  "hermes" \
  "$HERMES_SOURCE" \
  env HOME="$FIXTURE_HOME" HERMES_HOME="$HERMES_HOME_DIR" \
  bash "$ROOT/adapters/hermes/list_recent_sessions.sh" "$WORKSPACE"

OMP_DIR="${FIXTURE_HOME}/omp-sessions"
OMP_SOURCE="${OMP_DIR}/omp-session.jsonl"
mkdir -p "$OMP_DIR"
printf '{"type":"title","title":"fixture"}\n{"type":"session","id":"omp-session","cwd":"%s"}\n' \
  "$WORKSPACE" >"$OMP_SOURCE"
assert_source_path \
  "omp" \
  "$OMP_SOURCE" \
  env HOME="$FIXTURE_HOME" OMP_CODING_AGENT_SESSION_DIR="$OMP_DIR" \
  bash "$ROOT/adapters/omp/list_recent_sessions.sh" "$WORKSPACE"

if ! jq -e '
  .properties.sessions.items.properties
  | has("sourcePath") and has("sourceMtimeNanos") and has("sourceSize")
' "$ROOT/schemas/methods/list_recent_sessions.schema.json" >/dev/null; then
  printf '[FAIL] list_recent_sessions schema does not expose freshness metadata\n'
  FAILURES=$((FAILURES + 1))
else
  printf '[PASS] list_recent_sessions schema exposes freshness metadata\n'
fi

for adapter in claude-code codex antigravity cursor-agent opencode pi grok hermes omp; do
  manifest_version="$(jq -r '.version' "$ROOT/adapters/$adapter/adapter.json")"
  registry_version="$(jq -r --arg adapter "$adapter" '.adapters[] | select(.name == $adapter) | .version' "$ROOT/registry.json")"
  if [[ "$manifest_version" != "$registry_version" ]]; then
    printf '[FAIL] %s manifest/registry version mismatch (%s != %s)\n' \
      "$adapter" "$manifest_version" "$registry_version"
    FAILURES=$((FAILURES + 1))
  fi
done

if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi
