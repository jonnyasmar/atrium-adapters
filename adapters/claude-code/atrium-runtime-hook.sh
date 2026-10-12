#!/usr/bin/env bash
# atrium-runtime-hook.sh — every atrium Claude Code hook on Windows runs here.
#
# hooks.sh writes `<bash.exe> …/atrium-runtime-hook.sh <mode> …` into
# ~/.claude/settings.json on Windows instead of its inline POSIX commands.
# Claude Code runs either form through Git Bash, but Grok also runs this file's
# hooks, through PowerShell, where the POSIX ones are a ParserError (see
# ../shared/windows-hook-command.sh). Each mode repeats the guards and work of
# the inline command it replaces in hooks.sh; keep the two in step
# (tests/windows-hook-commands.assert.sh runs both against the same inputs).
#
#   entry <event>        lifecycle activity (claude-hook-entry.sh)
#   manifest <section>   SessionStart manifest section
#   sigils               prompt-time +name sigil context
#   inject <event>       hook-server context delivery (inject-context.sh)
#
# Builtins only until the guards pass: outside atrium this costs one bash.

# Grok sets GROK_HOOK_EVENT on every hook it runs, including the ones it reads
# from this settings file. It has its own atrium hooks, so these are only
# duplicates there.
[ -z "${GROK_HOOK_EVENT:-}" ] || exit 0

# Started from PowerShell or cmd (Claude Code without Git Bash, say), nothing
# set up the PATH Git Bash would have.
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

ADAPTER_DIR="${ATRIUM_DATA_DIR:-$HOME/.atrium}/adapters/claude-code"
CLI="${ATRIUM_CLI_PATH:-atrium}"

case "${1:-}" in
  entry)
    [ -n "${ATRIUM:-}" ] || exit 0
    # Sourced rather than run, here and for inject: one process fewer.
    shift
    . "$ADAPTER_DIR/claude-hook-entry.sh" "$@"
    ;;
  manifest)
    [ -z "${CURSOR_INVOKED_AS:-}" ] || exit 0
    [ -n "${ATRIUM:-}" ] || exit 0
    "$CLI" skills resolve-manifest --pane-id "${ATRIUM_PANE_ID:-}" --adapter claude-code --section "${2:-}" 2>/dev/null
    exit 0
    ;;
  sigils)
    [ -z "${CURSOR_INVOKED_AS:-}" ] || exit 0
    [ -z "${ATRIUM_CHAT_SDK_HOOKS:-}" ] || exit 0
    [ -n "${ATRIUM:-}" ] || exit 0
    "$CLI" skills resolve-prompt-sigils --pane-id "${ATRIUM_PANE_ID:-}" --adapter claude-code 2>/dev/null
    exit 0
    ;;
  inject)
    [ -z "${CURSOR_INVOKED_AS:-}" ] || exit 0
    # SessionStart keeps running for chat panes; see hooks.sh.
    [ "${2:-}" = session-start ] || [ -z "${ATRIUM_CHAT_SDK_HOOKS:-}" ] || exit 0
    [ -n "${ATRIUM:-}" ] || exit 0
    shift
    . "$ADAPTER_DIR/inject-context.sh" "$@"
    ;;
esac
exit 0
