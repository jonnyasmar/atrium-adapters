#!/usr/bin/env bash
# atrium-runtime-hook.sh — every atrium Grok hook on Windows runs through here.
#
# hooks.sh writes `<bash.exe> …/atrium-runtime-hook.sh <mode> …` on Windows
# instead of its inline POSIX commands, which PowerShell cannot parse (see
# ../shared/windows-hook-command.sh). Each mode repeats the guards and work of
# the inline command it replaces in hooks.sh; keep the two in step
# (tests/windows-hook-commands.assert.sh runs both against the same inputs).
#
#   emit <normalize-event> <emit-event>   lifecycle activity
#   manifest <section>                    SessionStart manifest section
#   sigils                                prompt-time +name sigil context
#   inject <event>                        hook-server context delivery
#
# Builtins only until the guards pass: outside atrium this costs one bash.

# Started from PowerShell or cmd (unless GROK_SHELL=bash), nothing set up the
# PATH Git Bash would have, and Windows' own find/sort/curl would shadow the
# MSYS ones.
case "${OSTYPE:-}" in
  msys* | cygwin*)
    if [ -z "${MSYSTEM:-}" ]; then
      for prefix in /mingw64 /clangarm64 /ucrt64; do
        if [ -d "$prefix/bin" ]; then
          PATH="$prefix/bin:$PATH"
          break
        fi
      done
      PATH="/usr/bin:$PATH"
    fi
    ;;
esac

ADAPTERS_DIR="${ATRIUM_DATA_DIR:-$HOME/.atrium}/adapters"
CLI="${ATRIUM_CLI_PATH:-atrium}"

case "${1:-}" in
  emit)
    [ -z "${ATRIUM_CHAT_SDK_HOOKS:-}" ] || exit 0
    [ -n "${ATRIUM_PANE_ID:-}" ] || exit 0
    "$ADAPTERS_DIR/grok/normalize-hook-payload.sh" "${2:-}" \
      | "$CLI" hook emit "${3:-}" --adapter grok --pane-id "$ATRIUM_PANE_ID" --json 2>/dev/null
    exit 0
    ;;
  manifest)
    [ -z "${ATRIUM_CHAT_SDK_HOOKS:-}" ] || exit 0
    [ -n "${ATRIUM:-}" ] || exit 0
    "$CLI" skills resolve-manifest --pane-id "${ATRIUM_PANE_ID:-}" --adapter grok --section "${2:-}" 2>/dev/null
    exit 0
    ;;
  sigils)
    if [ -n "${ATRIUM_CHAT_SDK_HOOKS:-}" ]; then
      printf '{}\n'
      exit 0
    fi
    [ -n "${ATRIUM:-}" ] && "$CLI" skills resolve-prompt-sigils --pane-id "${ATRIUM_PANE_ID:-}" --adapter grok 2>/dev/null \
      || printf '{}\n'
    exit 0
    ;;
  inject)
    # Sourced rather than run: one process fewer, and it has its own guards.
    shift
    . "$ADAPTERS_DIR/grok/inject-context.sh" "$@"
    ;;
esac
exit 0
