#!/usr/bin/env bash
# The plugin adapters (opencode, pi, omp) run atrium's catastrophic-command
# guard from inside the agent's own process: before a shell tool runs, they
# ask `atrium guard check --command … --format json` and refuse (opencode:
# throw; pi/omp: `{ block, reason }`) only when it says so. This loads each real
# plugin module and pins: the refusal reaches the agent with the CLI's reason,
# other commands and tools pass, an atrium CLI from before `guard` never
# blocks, and nothing is asked outside an atrium pane. Needs Node with
# TypeScript type stripping (22.18+/23.6+).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/atrium-plugin-guard.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

pass() { printf '[PASS] %s\n' "$1"; }
fail() {
  printf '[FAIL] %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}
expect() {
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1: expected [$2], got [$3]"; fi
}

cat >"$TMP/atrium" <<'EOF'
#!/bin/sh
echo "$*" >>"$CALLS"
case "$*" in
  "guard check --command "*atrium-guard-test-refuse*) echo '{"verdict":"refuse","rule":"R1","message":"refused by the guard"}' ;;
  "guard check "*) echo '{"verdict":"allow"}' ;;
esac
exit 0
EOF
cat >"$TMP/old-atrium" <<'EOF'
#!/bin/sh
echo "$*" >>"$CALLS"
case "$1" in guard) echo "error: unrecognized subcommand 'guard'" >&2; exit 2 ;; esac
exit 0
EOF
chmod +x "$TMP/atrium" "$TMP/old-atrium"
CALLS="$TMP/calls"

run() { # <adapter> <cli> <pane: yes|no> <tool> <command>
  local pane=()
  [ "$3" = yes ] && pane=(ATRIUM=1 ATRIUM_PANE_ID=pane-1)
  : >"$CALLS"
  env -i HOME="$TMP" PATH="/usr/bin:/bin:$(dirname "$(command -v node)")" CALLS="$CALLS" \
    ATRIUM_CLI_PATH="$TMP/$2" ATRIUM_PLUGIN_DEBUG=0 ATRIUM_PI_EXTENSION_DEBUG=0 \
    ATRIUM_OMP_EXTENSION_DEBUG=0 ${pane[@]+"${pane[@]}"} \
    node "$ROOT/tests/plugin-command-guard-runner.mjs" "$1" "$4" "$5" 2>/dev/null
}
guard_calls() { grep -c '^guard check' "$CALLS" || true; }

for adapter in opencode pi omp; do
  expect "$adapter: refuses with the guard's reason" \
    '{"outcome":"refused","reason":"refused by the guard"}' \
    "$(run "$adapter" atrium yes bash 'rm -rf ~ atrium-guard-test-refuse')"
  expect "$adapter: allows another command" '{"outcome":"allowed"}' \
    "$(run "$adapter" atrium yes bash 'rm -rf node_modules')"
  expect "$adapter: an old CLI never blocks" '{"outcome":"allowed"}' \
    "$(run "$adapter" old-atrium yes bash 'rm -rf ~ atrium-guard-test-refuse')"
  expect "$adapter: outside atrium it asks nothing" '{"outcome":"allowed"}|0' \
    "$(run "$adapter" atrium no bash 'rm -rf ~ atrium-guard-test-refuse')|$(guard_calls)"
  expect "$adapter: a non-shell tool asks nothing" '{"outcome":"allowed"}|0' \
    "$(run "$adapter" atrium yes read 'atrium-guard-test-refuse')|$(guard_calls)"
done
expect "pi: a powershell command goes to the guard as PowerShell" "1" \
  "$(run pi atrium yes powershell 'Remove-Item -Recurse C:\' >/dev/null; grep -c -- '--shell powershell' "$CALLS" || true)"

if [ "$FAILURES" -ne 0 ]; then
  printf '%d failure(s)\n' "$FAILURES"
  exit 1
fi
