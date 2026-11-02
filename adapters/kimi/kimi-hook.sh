#!/usr/bin/env bash
set -uo pipefail

NORMALIZER_EVENT="${1:-}"
ATRIUM_EVENT="${2:-$NORMALIZER_EVENT}"
PAYLOAD="$(cat 2>/dev/null || true)"

if [[ -z "${ATRIUM_PANE_ID:-}" ]]; then
  [[ "$NORMALIZER_EVENT" == "user-prompt-submit" ]] && printf '{}\n'
  exit 0
fi

if [[ -n "${ATRIUM_CHAT_SDK_HOOKS:-}" && "$NORMALIZER_EVENT" != "pre-tool-use" ]]; then
  [[ "$NORMALIZER_EVENT" == "user-prompt-submit" ]] && printf '{}\n'
  exit 0
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$(cd "$DIR/../.." 2>/dev/null && pwd || printf '%s' "$HOME/.atrium")"
case "$(basename "$DATA_DIR")" in
  .atrium-dev*) DEFAULT_CLI="$DATA_DIR/bin/atrium-dev" ;;
  *) DEFAULT_CLI="$DATA_DIR/bin/atrium" ;;
esac
ATRIUM_CLI="${ATRIUM_CLI_PATH:-$DEFAULT_CLI}"
[[ -x "$ATRIUM_CLI" ]] || ATRIUM_CLI="atrium"

# Catastrophic-command guard, in terminal and chat panes alike: `atrium guard
# check` prints kimi's deny for a command that could erase /, the home folder,
# system folders or a disk, and nothing otherwise. Only a JSON object on stdout
# refuses; an atrium CLI from before `guard` prints its usage error to stderr,
# which is dropped, so it can never block a command.
GUARD=""
if [[ "$NORMALIZER_EVENT" == "pre-tool-use" ]]; then
  case "$PAYLOAD" in
    *Bash* | *Shell*)
      GUARD="$(printf '%s' "$PAYLOAD" | "$ATRIUM_CLI" guard check --adapter kimi 2>/dev/null)" || true
      [[ "$GUARD" == "{"* ]] || GUARD=""
      ;;
  esac
  if [[ -n "${ATRIUM_CHAT_SDK_HOOKS:-}" ]]; then
    [[ -z "$GUARD" ]] || printf '%s\n' "$GUARD"
    exit 0
  fi
fi

debug() {
  [[ "${ATRIUM_HOOK_DEBUG:-0}" == "0" ]] && return 0
  printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$NORMALIZER_EVENT" "$1" >>"${TMPDIR:-/tmp}/atrium-kimi-hooks.log"
}

debug "stdin=$(printf '%s' "$PAYLOAD" | head -c 2000)"

case "$NORMALIZER_EVENT" in
  session-start)
    printf '%s' "$PAYLOAD" | "$DIR/inject-context.sh" --reset >/dev/null 2>&1 || true
    ;;
  session-end)
    printf '%s' "$PAYLOAD" | "$DIR/inject-context.sh" --cleanup >/dev/null 2>&1 || true
    ;;
esac

printf '%s' "$PAYLOAD" \
  | "$DIR/normalize-hook-payload.sh" "$NORMALIZER_EVENT" 2>/dev/null \
  | "$ATRIUM_CLI" hook emit "$ATRIUM_EVENT" \
      --adapter kimi --pane-id "$ATRIUM_PANE_ID" --json >/dev/null 2>&1 || true

debug "emit=$ATRIUM_EVENT"

if [[ "$NORMALIZER_EVENT" == "user-prompt-submit" ]]; then
  printf '%s' "$PAYLOAD" | "$DIR/inject-context.sh"
fi
[[ -z "$GUARD" ]] || printf '%s\n' "$GUARD"

exit 0
