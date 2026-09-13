#!/usr/bin/env bash
set -euo pipefail

# build_launch_command.sh — Build the command to launch Grok.
# Takes $1 = JSON flags from launcher options
# Output: {"command": ["env", "GROK_DISABLE_AUTOUPDATER=1", "<wrapper>", ...flags]}
#
# argv[0] is grok-with-atrium-rules.sh (not bare `grok`) so atrium-context
# + the pane-rename instruction are injected via `grok --rules` inside the
# wrapper. Multi-line rules must NOT appear in this argv — atrium types it
# into the shell with an unquoted `cmd.join(" ")`.
#
# jq filter is a single expression with explicit parens: atrium's script
# PATH prefers /usr/bin/jq (Apple 1.7.1), which rejects multi-line
# `command: [$x] + …` without grouping (homebrew jq 1.8 is more lenient).

FLAGS="${1:-"{}"}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/grok-with-atrium-rules.sh"

# Windows: atrium joins this argv with spaces and types it into the pane shell,
# which is PowerShell by default. NEITHER piece of the Unix argv survives there:
# `env` is not a PowerShell command, and a .sh wrapper cannot be argv[0] because
# PowerShell cannot exec it and a bare `bash` word resolves to the WSL launcher
# at C:\Windows\system32\bash.exe rather than Git Bash (measured on a stock
# Windows 11 box; Git Bash is at C:\Program Files\Git\bin\bash.exe, not on PATH,
# and its space-bearing path could not survive the unquoted join anyway).
# So Windows launches the bare binary.
# RECORDED DIVERGENCE: the atrium-rules context injection the wrapper performs
# (grok --rules with atrium-context + the pane-rename instruction) is therefore
# NOT applied on Windows. Everything else about the launch is identical.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "$FLAGS" | jq empty 2>/dev/null || FLAGS='{}'
      jq -nc --argjson flags "$FLAGS" \
        '{command: (["grok"] + (if $flags.alwaysApprove == true then ["--always-approve"] else [] end) + (if (($flags.model // "") | length) > 0 then ["--model", $flags.model] else [] end) + (if (($flags.effort // "") | length) > 0 then ["--reasoning-effort", $flags.effort] else [] end) + (if (($flags.extraArgs // "") | length) > 0 then ($flags.extraArgs | split(" ") | map(select(length > 0))) else [] end))}'
    else
      echo '{"command": ["grok"]}'
    fi
    exit 0
    ;;
esac

if [ ! -f "$WRAPPER" ]; then
  echo '{"command": ["env", "GROK_DISABLE_AUTOUPDATER=1", "grok"]}'
  exit 0
fi

if ! command -v jq &>/dev/null; then
  printf '{"command":["env", "GROK_DISABLE_AUTOUPDATER=1",%s]}\n' "$(printf '%s' "$WRAPPER" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
  exit 0
fi

if ! printf '%s' "$FLAGS" | jq empty 2>/dev/null; then
  FLAGS='{}'
fi

jq -nc \
  --arg wrapper "$WRAPPER" \
  --argjson flags "$FLAGS" \
  '{command: (["env", "GROK_DISABLE_AUTOUPDATER=1", $wrapper] + (if $flags.alwaysApprove == true then ["--always-approve"] else [] end) + (if (($flags.model // "") | length) > 0 then ["--model", $flags.model] else [] end) + (if (($flags.effort // "") | length) > 0 then ["--reasoning-effort", $flags.effort] else [] end) + (if (($flags.extraArgs // "") | length) > 0 then ($flags.extraArgs | split(" ") | map(select(length > 0))) else [] end))}'
exit 0
