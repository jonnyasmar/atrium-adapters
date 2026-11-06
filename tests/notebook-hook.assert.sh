#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR:?}"' EXIT
mkdir -p "$TEMP_DIR/home" "$TEMP_DIR/bin" "$TEMP_DIR/data"
HOME="$TEMP_DIR/home" bash "$ROOT/adapters/claude-code/hooks.sh" install >/dev/null
jq -e '[.hooks.SessionStart[].hooks[].command | select(contains("memory notebook --context"))] | length == 1' "$TEMP_DIR/home/.claude/settings.json" >/dev/null
printf '12345' > "$TEMP_DIR/data/hook-port"
cat > "$TEMP_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  if [ "$1" = --data-binary ]; then
    shift
    printf '%s' "$1" > "$PAYLOAD_FILE"
  fi
  shift
done
printf '{"atriumContext":"Ambient only"}'
STUB
chmod +x "$TEMP_DIR/bin/curl"
RESULT="$(printf '{"source":"startup"}' | PATH="$TEMP_DIR/bin:$PATH" ATRIUM=1 ATRIUM_DATA_DIR="$TEMP_DIR/data" PAYLOAD_FILE="$TEMP_DIR/payload" bash "$ROOT/adapters/claude-code/inject-context.sh" session-start)"
[ "$RESULT" = "Ambient only" ]
jq -e '.atriumNotebookHook == true and .source == "startup"' "$TEMP_DIR/payload" >/dev/null
printf 'Notebook hook installation and ambient split marker passed\n'
