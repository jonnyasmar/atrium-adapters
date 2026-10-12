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
# pass the adapter's `atrium-runtime-hook.sh` and append plain-word arguments:
#
#   <bash.exe> <data-dir>/adapters/<name>/atrium-runtime-hook.sh <mode> [args]
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

# atrium_windows_hook_launcher <data-dir> <adapter-name>
#
# Prints "<bash.exe> <script>" for the adapter's atrium-runtime-hook.sh, or
# fails when no plain form exists (8.3 names disabled on a path with spaces).
#
# Only the data dir is shortened: the adapters/<name>/atrium-runtime-hook.sh
# tail stays literal so the ownership marker survives. MSYS's own bash.exe is
# one process; Git's bin/bash.exe launcher re-execs into it and costs a second
# (71 vs 93 ms per hook run the way Claude Code runs it, on a Windows 11 box).
# atrium-runtime-hook.sh sets up the PATH that launcher would have.
atrium_windows_hook_launcher() {
  local data_dir bash_exe
  bash_exe="$(atrium_windows_plain_path /usr/bin/bash.exe)" || return 1
  data_dir="$(atrium_windows_plain_path "$1")" || return 1
  printf '%s %s/adapters/%s/atrium-runtime-hook.sh' "$bash_exe" "${data_dir%/}" "$2"
}
