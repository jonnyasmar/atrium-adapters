#!/usr/bin/env bash
set -uo pipefail
[ -n "${ATRIUM_PANE_ID:-}" ] || exit 0
# The pane's env names its atrium instance; arguments after the event come
# from configs older atrium releases wrote and are ignored.
export ATRIUM_DATA_DIR="${ATRIUM_DATA_DIR:-$HOME/.atrium}"
export ATRIUM_CLI_PATH="${ATRIUM_CLI_PATH:-atrium}"
event="${1:-}"

# Catastrophic-command guard, in terminal and chat panes alike: `atrium guard
# check` prints Copilot's deny for a command that could erase /, the home
# folder, system folders or a disk, and nothing otherwise. Only a JSON object
# on stdout refuses; an atrium CLI from before `guard` prints its usage error
# to stderr, which is dropped, so it can never block a command.
guard=""
if [ "$event" = preToolUse ]; then
  payload="$(cat)"
  case "$payload" in
    *bash* | *powershell*)
      guard="$(printf '%s' "$payload" | "$ATRIUM_CLI_PATH" guard check --adapter copilot 2>/dev/null)" || true
      ;;
  esac
  case "$guard" in "{"*) ;; *) guard="" ;; esac
fi
answer() { [ -z "$guard" ] || printf '%s\n' "$guard"; }

[ "${ATRIUM_CHAT_SDK_HOOKS:-}" != 1 ] || { answer; exit 0; }
adapter_dir="${ATRIUM_DATA_DIR}/adapters/copilot"
[ -f "$adapter_dir/hooks.py" ] || { answer; exit 0; }
if [ -n "$guard" ]; then
  # The refusal is the hook's answer; the activity emit still goes out.
  printf '%s' "$payload" | bash "$adapter_dir/run-python.sh" "$adapter_dir/hooks.py" emit "$event" >/dev/null 2>&1
  answer
elif [ "$event" = preToolUse ]; then
  printf '%s' "$payload" | bash "$adapter_dir/run-python.sh" "$adapter_dir/hooks.py" emit "$event" || printf '{}\n'
else
  bash "$adapter_dir/run-python.sh" "$adapter_dir/hooks.py" emit "$event" || printf '{}\n'
fi
# Copilot's preToolUse is fail-closed on a nonzero exit. An unavailable
# atrium bridge must never deny a tool or grant additional permissions.
exit 0
