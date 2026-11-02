#!/usr/bin/env bash
# windows-hook-command.sh — interpreter-neutral hook commands for Windows.
#
# On Windows a hook command runs under whatever shell its host picks. Grok
# tries pwsh, then Windows PowerShell, then Git Bash (GROK_SHELL overrides
# that), and it also runs ~/.claude/settings.json hooks through its Claude
# compatibility. Claude Code uses Git Bash. The POSIX commands written
# elsewhere (`[ … ] || exit 0`, `${VAR:-…}`, pipes) are a ParserError in
# PowerShell, so every one of them failed there (issue #155).
#
# A command made of nothing but paths and plain words means the same thing in
# PowerShell, cmd and Git Bash, so it runs whichever one the host picks. Callers
# get a launcher for the adapter's `atrium-runtime-hook.sh` (through a shim in
# the tool's config dir) and append plain-word arguments:
#
#   <bash.exe> <config-dir>/atrium-runtime-hook.sh <mode> [args]
#
# The script is named after the ownership marker on purpose: every installer's
# ATRIUM_HOOK_MARKER_RE already matches `atrium-runtime-hook`, so older
# adapters still recognise (and replace) these commands.

atrium_hooks_on_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) return 0 ;;
  esac
  return 1
}

# Prints a Windows path with forward slashes that needs no quoting in any
# shell, falling back to its 8.3 short form for a path with spaces or other
# shell characters. Fails when neither form is plain.
atrium_windows_plain_path() {
  local path
  path="$(cygpath -m "$1" 2>/dev/null)" || return 1
  case "$path" in
    *[!A-Za-z0-9_.~/:-]*) path="$(cygpath -ms "$path" 2>/dev/null)" || return 1 ;;
  esac
  case "$path" in
    "" | *[!A-Za-z0-9_.~/:-]*) return 1 ;;
  esac
  printf '%s' "$path"
}

# atrium_windows_hook_launcher <adapter-name> <config-dir>
#
# Prints "<bash.exe> <config-dir>/atrium-runtime-hook.sh"; install writes that
# file with atrium_windows_write_hook_shim. It is an instance-neutral shim, the
# same bytes whichever atrium instance (stable, dev, each worktree) installs
# it, that runs the pane's own instance's adapters/<name>/atrium-runtime-hook.sh,
# picked from $ATRIUM_DATA_DIR at fire time. The hook config is global and
# every instance installs it, so it must never name one instance's data dir.
# Fails when no plain form exists (8.3 names disabled on a path with spaces).
#
# Only the dir is shortened: the atrium-runtime-hook.sh tail stays literal so
# the ownership marker survives. MSYS's own bash.exe is one process; Git's
# bin/bash.exe launcher re-execs into it and costs a second (71 vs 93 ms per
# hook run the way Claude Code runs it, on a Windows 11 box).
# atrium-runtime-hook.sh sets up the PATH that launcher would have.
atrium_windows_hook_launcher() {
  local dir="$2" bash_exe plain_dir
  mkdir -p "$dir" || return 1
  bash_exe="$(atrium_windows_plain_path /usr/bin/bash.exe)" || return 1
  plain_dir="$(atrium_windows_plain_path "$dir")" || return 1
  printf '%s %s/atrium-runtime-hook.sh' "$bash_exe" "${plain_dir%/}"
}

# atrium_windows_write_hook_shim <adapter-name> <config-dir>
atrium_windows_write_hook_shim() {
  local shim="$2/atrium-runtime-hook.sh" body
  body="$(atrium_windows_hook_shim "$1")"
  [ -f "$shim" ] && [ "$(cat "$shim")" = "$body" ] && return 0
  mkdir -p "$2"
  printf '%s\n' "$body" >"$shim.atrium-tmp" && mv "$shim.atrium-tmp" "$shim"
}

atrium_windows_hook_shim() {
  printf '%s\n' '#!/usr/bin/env bash' \
    "# Written by atrium's $1 adapter; the same for every atrium instance." \
    "target=\"\${ATRIUM_DATA_DIR:-\$HOME/.atrium}/adapters/$1/atrium-runtime-hook.sh\"" \
    '[ -f "$target" ] || exit 0' \
    'exec "$BASH" "$target" "$@"'
}
