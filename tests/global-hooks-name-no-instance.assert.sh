#!/usr/bin/env bash
# Every adapter's hooks.sh writes into the agent CLI's GLOBAL config, and every
# atrium instance on the machine (stable, dev, each linked worktree) runs that
# install on boot. A config that names the installing instance's data dir
# breaks every other instance's panes once that dir goes away — for Copilot
# and Antigravity, which deny a tool call when their hook fails, it blocked
# every tool call. So, per adapter: installing from two different instances'
# data dirs must write the same bytes, and those bytes must name neither.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/atrium-global-hooks.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

pass() { printf '[PASS] %s\n' "$1"; }
fail() {
  printf '[FAIL] %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

JQ_DIR="$(dirname "$(command -v jq)")"
BASE_PATH="/usr/bin:/bin:$JQ_DIR"

# Hermes edits config.yaml with a YAML library; CI provides one on PATH.
yaml_python() {
  local p
  for p in "${HERMES_VENV_PYTHON:-}" "$(command -v python3 2>/dev/null)"; do
    [ -n "$p" ] && "$p" -c 'import ruamel.yaml' >/dev/null 2>&1 && { echo "$p"; return; }
    [ -n "$p" ] && "$p" -c 'import yaml' >/dev/null 2>&1 && { echo "$p"; return; }
  done
}
YAML_PYTHON="$(yaml_python || true)"

# Everything under the fake home except the instances' own data dirs, as
# "<path> <sha256>" lines (allowlists carry timestamps, so hermes's is checked
# for instance names only).
snapshot() {
  (cd "$1" && find . -type f ! -path './.atrium-dev-*' ! -name 'shell-hooks-allowlist.json' \
    ! -name '*.atrium-bak' ! -name '*.atrium-backup' -print0 \
    | sort -z | xargs -0 shasum -a 256)
}

for dir in "$ROOT"/adapters/*/; do
  adapter="$(basename "$dir")"
  [ -f "$dir/hooks.sh" ] && [ -f "$dir/adapter.json" ] || continue
  home="$TMP/$adapter"
  mkdir -p "$home"
  extra=()
  if [ "$adapter" = hermes ]; then
    if [ -z "$YAML_PYTHON" ]; then
      printf '[SKIP] hermes: no python with a YAML library\n'
      continue
    fi
    extra=(HERMES_VENV_PYTHON="$YAML_PYTHON")
  fi
  for instance in probe-a probe-b; do
    data="$home/.atrium-dev-$instance"
    mkdir -p "$data/adapters"
    # Run from the instance's own adapter dir, the way atrium installs it.
    [ -e "$data/adapters/$adapter" ] || ln -s "$dir" "$data/adapters/$adapter"
    [ -e "$data/adapters/shared" ] || ln -s "$ROOT/adapters/shared" "$data/adapters/shared"
    env -i HOME="$home" PATH="$BASE_PATH" ATRIUM_DATA_DIR="$data" ${extra[@]+"${extra[@]}"} \
      bash "$data/adapters/$adapter/hooks.sh" install >/dev/null 2>"$TMP/$adapter-install-$instance.err" || true
    snapshot "$home" >"$TMP/$adapter-snapshot-$instance"
  done
  if [ ! -s "$TMP/$adapter-snapshot-probe-a" ]; then
    printf '[SKIP] %s: install wrote nothing global\n' "$adapter"
    continue
  fi
  if diff -q "$TMP/$adapter-snapshot-probe-a" "$TMP/$adapter-snapshot-probe-b" >/dev/null; then
    pass "$adapter: every instance writes the same bytes"
  else
    fail "$adapter: installs from two instances differ: $(diff "$TMP/$adapter-snapshot-probe-a" "$TMP/$adapter-snapshot-probe-b" | head -4 | tr '\n' ' ')"
  fi
  named="$(cd "$home" && find . -type f ! -path './.atrium-dev-*' -print0 \
    | xargs -0 grep -l 'atrium-dev-probe' 2>/dev/null || true)"
  if [ -z "$named" ]; then
    pass "$adapter: nothing names an instance"
  else
    fail "$adapter: names an instance in: $named"
  fi
done

if [ "$FAILURES" -ne 0 ]; then
  printf '%d failure(s)\n' "$FAILURES"
  exit 1
fi
