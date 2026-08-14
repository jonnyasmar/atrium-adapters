#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Codex sessions for a CWD.
# Uses the indexed Codex thread registry when it exposes resumability metadata,
# then falls back to rollout JSONL files and the legacy SQLite shape.
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive, sourcePath}, ...]}

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"
SESSIONS_DIR="${HOME}/.codex/sessions"
DB_PATH="${HOME}/.codex/state_5.sqlite"

# ── Strategy 1: modern SQLite registry, then rollout files ──
if { [ -d "$SESSIONS_DIR" ] || [ -f "$DB_PATH" ]; } && command -v python3 &>/dev/null; then
  RESULT=$(python3 -c "
import json, os, glob, sqlite3, sys
from datetime import datetime, timezone

cwd = sys.argv[1]
sessions_dir = sys.argv[2]
db_path = sys.argv[3]
sessions = []

# Modern Codex maintains an indexed thread registry with both direct-resume
# classification and real activity recency. Prefer it over walking thousands
# of rollout files; the rollout remains the transcript source path.
if os.path.isfile(db_path):
    try:
        conn = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True, timeout=0.1)
        columns = {row[1] for row in conn.execute('PRAGMA table_info(threads)')}
        required = {'thread_source', 'rollout_path', 'recency_at_ms'}
        if required.issubset(columns):
            rows = conn.execute('''
                SELECT id, title, first_user_message, rollout_path,
                       COALESCE(NULLIF(recency_at_ms, 0), updated_at * 1000)
                FROM threads
                WHERE cwd = ? AND archived = 0
                  AND COALESCE(thread_source, '') <> 'subagent'
                ORDER BY recency_at_ms DESC
                LIMIT 10
            ''', (cwd,)).fetchall()
            for sid, title, first_user_message, source_path, activity_ms in rows:
                if not sid or not source_path or not os.path.isfile(source_path):
                    continue
                name = title or first_user_message or None
                if name:
                    name = name[:80]
                sessions.append({
                    'id': sid,
                    'name': name,
                    'cwd': cwd,
                    'lastActive': datetime.fromtimestamp(activity_ms / 1000, timezone.utc).isoformat().replace('+00:00', 'Z'),
                    'sourcePath': source_path,
                })
        conn.close()
    except (OSError, sqlite3.Error, ValueError, TypeError):
        sessions = []

if sessions:
    print(json.dumps({'sessions': sessions}))
    raise SystemExit(0)

# Rollout creation time does not move as a long-running thread stays active.
# File mtime does, so it is the picker recency source of truth.
paths = glob.glob(os.path.join(sessions_dir, '*/*/*/rollout-*.jsonl'))
paths.sort(key=lambda path: os.path.getmtime(path), reverse=True)
for path in paths:
    if len(sessions) >= 20:
        break
    try:
        with open(path) as f:
            first_line = f.readline()
        meta = json.loads(first_line)
        if meta.get('type') != 'session_meta':
            continue
        payload = json.loads(meta['payload']) if isinstance(meta.get('payload'), str) else meta.get('payload', {})
        if payload.get('cwd') != cwd:
            continue
        source = payload.get('source') if isinstance(payload.get('source'), dict) else {}
        has_subagent_source = any(isinstance(source.get(key), dict) for key in ('subagent', 'subAgent', 'SubAgent'))
        if (
            payload.get('thread_source') == 'subagent'
            or payload.get('parent_thread_id')
            or payload.get('parentThreadId')
            or has_subagent_source
        ):
            continue
        sid = payload.get('id', '')
        if not sid:
            continue
        ts = datetime.fromtimestamp(os.path.getmtime(path), timezone.utc).isoformat().replace('+00:00', 'Z')
        sessions.append({
            'id': sid,
            'name': None,
            'cwd': cwd,
            'lastActive': ts,
            'sourcePath': path
        })
    except (json.JSONDecodeError, IOError, KeyError):
        continue

# Get first user message as name from history.jsonl
history_path = os.path.expanduser('~/.codex/history.jsonl')
if os.path.exists(history_path) and sessions:
    sid_set = {s['id'] for s in sessions}
    sid_names = {}
    try:
        with open(history_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                entry = json.loads(line)
                sid = entry.get('session_id', '')
                if sid in sid_set and sid not in sid_names:
                    text = entry.get('text', '')
                    if text:
                        sid_names[sid] = text[:80]
    except (json.JSONDecodeError, IOError):
        pass
    for s in sessions:
        if s['id'] in sid_names:
            s['name'] = sid_names[s['id']]

# Sort by lastActive descending, limit to 10
sessions.sort(key=lambda s: s.get('lastActive', ''), reverse=True)
print(json.dumps({'sessions': sessions[:10]}))
" "$CWD" "$SESSIONS_DIR" "$DB_PATH" 2>/dev/null)

  if [ -n "$RESULT" ] && [ "$RESULT" != '{"sessions": []}' ]; then
    echo "$RESULT"
    exit 0
  fi
fi

# ── Strategy 2: SQLite fallback (older Codex versions) ──
if ! command -v sqlite3 &>/dev/null; then
  echo '{"sessions": []}'
  exit 0
fi

if [ ! -f "$DB_PATH" ]; then
  echo '{"sessions": []}'
  exit 0
fi

ESCAPED_CWD="${CWD//\'/\'\'}"

THREAD_SOURCE_FILTER=""
HAS_THREAD_SOURCE="$(sqlite3 -readonly "$DB_PATH" \
  "SELECT COUNT(*) FROM pragma_table_info('threads') WHERE name = 'thread_source'" 2>/dev/null)" || \
HAS_THREAD_SOURCE="$(sqlite3 "$DB_PATH" \
  "SELECT COUNT(*) FROM pragma_table_info('threads') WHERE name = 'thread_source'" 2>/dev/null)" || true
if [ "$HAS_THREAD_SOURCE" = "1" ]; then
  THREAD_SOURCE_FILTER=" AND COALESCE(thread_source, '') <> 'subagent'"
fi

# Try -readonly first, fall back to normal open (macOS quarantine xattr)
RAW="$(sqlite3 -json -readonly "$DB_PATH" \
  "SELECT id, cwd, title, updated_at, first_user_message FROM threads WHERE cwd = '${ESCAPED_CWD}' AND archived = 0${THREAD_SOURCE_FILTER} ORDER BY updated_at DESC LIMIT 10" 2>/dev/null)" || \
RAW="$(sqlite3 -json "$DB_PATH" \
  "SELECT id, cwd, title, updated_at, first_user_message FROM threads WHERE cwd = '${ESCAPED_CWD}' AND archived = 0${THREAD_SOURCE_FILTER} ORDER BY updated_at DESC LIMIT 10" 2>/dev/null)" || {
  echo '{"sessions": []}'
  exit 0
}

if [ -z "$RAW" ] || [ "$RAW" = "[]" ]; then
  echo '{"sessions": []}'
  exit 0
fi

if command -v jq &>/dev/null; then
  echo "$RAW" | jq --arg cwd "$CWD" --arg source_path "$DB_PATH" '
    [.[] | {
      id: .id,
      name: (
        if (.title // "") != "" then .title
        elif (.first_user_message // "") != "" then
          (.first_user_message | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
           | if length > 50 then .[:47] + "..." else . end)
        else null end
      ),
      cwd: (.cwd // $cwd),
      lastActive: (.updated_at | tonumber | todate),
      sourcePath: $source_path
    }] | {sessions: .}'
elif command -v perl &>/dev/null; then
  CODEX_SESSION_CWD="$CWD" CODEX_SESSION_SOURCE="$DB_PATH" perl -MJSON::PP -MPOSIX=strftime -e '
    local $/;
    my $rows = decode_json(<STDIN>);
    my @sessions;
    for my $row (@$rows) {
      my $name = $row->{title} // "";
      $name = $row->{first_user_message} // "" if $name eq "";
      $name =~ s/\s+/ /g;
      $name =~ s/^ | $//g;
      $name = substr($name, 0, 47) . "..." if length($name) > 50;
      push @sessions, {
        id => $row->{id},
        name => $name eq "" ? undef : $name,
        cwd => $row->{cwd} // $ENV{CODEX_SESSION_CWD},
        lastActive => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(0 + $row->{updated_at})),
        sourcePath => $ENV{CODEX_SESSION_SOURCE},
      };
    }
    print encode_json({sessions => \@sessions});
  ' <<<"$RAW"
else
  echo "{\"sessions\": ${RAW}}"
fi

exit 0
