#!/usr/bin/env bash
# grok-with-atrium-rules.sh — exec `grok` with atrium session rules prepended.
#
# Why a wrapper: atrium types adapter launch argv into a shell via
# `cmd.join(" ")` (no shell quoting). Embedding multi-line `--rules` text
# in argv therefore inserts raw newlines into the typed line — the first
# newline submits a truncated command and leaves an empty prompt.
#
# build_launch_command / build_resume_command return this wrapper as
# argv[0] with only single-line, space-free-enough flags after it. Rules
# are loaded here via command substitution, never through the PTY line.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES=""
if [ -f "${SCRIPT_DIR}/atrium-session-rules.sh" ]; then
  RULES="$(bash "${SCRIPT_DIR}/atrium-session-rules.sh" 2>/dev/null || true)"
fi

if [ -n "$RULES" ]; then
  exec grok --rules "$RULES" "$@"
else
  exec grok "$@"
fi
