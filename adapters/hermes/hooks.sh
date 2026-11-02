#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Hermes hook installation for atrium.
#
# Hermes registers shell hooks under the `hooks:` block of config.yaml and
# gates first use of each (event, command) pair behind a TTY consent prompt.
# Install therefore does two things, both delegated to manage_hermes_config.py
# (which uses Hermes's own ruamel.yaml for a comment-preserving round-trip):
#   1. write one atrium hook entry per Hermes event into config.yaml `hooks:`
#   2. pre-seed ~/.hermes/shell-hooks-allowlist.json so an atrium-launched
#      `hermes chat` never blocks on the consent prompt
#
# Subcommands: install, uninstall, status. JSON to stdout, diagnostics to stderr.

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
CONFIG_YAML="${HERMES_HOME}/config.yaml"
ALLOWLIST="${HERMES_HOME}/shell-hooks-allowlist.json"
HOOK_SCRIPT="${ADAPTER_DIR}/hermes-hook.sh"
NORMALIZER="${ADAPTER_DIR}/normalize-hook-payload.sh"
INJECT_SCRIPT="${ADAPTER_DIR}/inject-context.sh"
PYHELPER="${ADAPTER_DIR}/manage_hermes_config.py"

# Hermes runs a hook command without a shell, so nothing in it expands at fire
# time — and every atrium instance (stable, dev, each worktree) installs into
# this one config. The commands therefore name no instance: they run a shim
# beside config.yaml, the same bytes whoever writes it, which picks the pane's
# own instance from $ATRIUM_DATA_DIR and answers `{}` by itself outside an
# atrium pane or when that instance's adapter is gone.
SHIM="${HERMES_HOME}/atrium-hook.sh"
SHIM_BODY='#!/usr/bin/env bash
# Written by atrium'"'"'s hermes adapter; the same for every atrium instance.
dir="${ATRIUM_DATA_DIR:-$HOME/.atrium}/adapters/hermes"
case "${1:-}" in
  hook) script="$dir/hermes-hook.sh" ;;
  inject) script="$dir/inject-context.sh" ;;
  *) script="" ;;
esac
if [ -z "${ATRIUM_PANE_ID:-}" ] || [ -z "$script" ] || [ ! -f "$script" ]; then
  printf '"'"'{}\n'"'"'
  exit 0
fi
shift
exec bash "$script" "$@"'

# Substrings that identify atrium-owned hook commands in config.yaml /
# allowlist: the shim, and the per-instance script paths older installs wrote,
# so a (re)install cleans up any prior atrium entry before writing its own.
MARKER="adapters/hermes/|${SHIM}"

write_shim() {
  if [ -f "$SHIM" ] && [ "$(cat "$SHIM")" = "$SHIM_BODY" ]; then
    return
  fi
  mkdir -p "$HERMES_HOME"
  printf '%s\n' "$SHIM_BODY" >"$SHIM.atrium-tmp"
  chmod 0755 "$SHIM.atrium-tmp"
  mv "$SHIM.atrium-tmp" "$SHIM"
}

# Hermes shell-hook event names we wire. The key in config.yaml IS the Hermes
# event name; hermes-hook.sh maps each to the atrium event(s) it emits.
HERMES_EVENTS="on_session_start pre_llm_call pre_tool_call post_tool_call post_llm_call"

if ! command -v jq >/dev/null 2>&1; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

# Resolve a Python interpreter that can import a YAML library. Hermes ships
# ruamel.yaml in its own venv, so prefer that; fall back to any python3 with a
# yaml lib. Parses the `hermes` launcher (a bash wrapper that exec's the venv
# binary, or a console-script with a python shebang) to find the venv.
resolve_python() {
  local candidates=() launcher venvbin sb p
  [ -n "${HERMES_VENV_PYTHON:-}" ] && candidates+=("$HERMES_VENV_PYTHON")
  launcher="$(command -v hermes 2>/dev/null || true)"
  if [ -n "$launcher" ] && [ -f "$launcher" ]; then
    venvbin="$(grep -oE '"[^"]*/bin/hermes"' "$launcher" 2>/dev/null | head -1 | tr -d '"')"
    [ -n "$venvbin" ] && candidates+=("$(dirname "$venvbin")/python3")
    sb="$(head -1 "$launcher" 2>/dev/null || true)"
    case "$sb" in
      \#!*python*) p="${sb#\#!}"; candidates+=("${p%% *}") ;;
    esac
  fi
  candidates+=("$HOME/.hermes/hermes-agent/venv/bin/python3" "$HOME/.hermes/venv/bin/python3")
  command -v python3 >/dev/null 2>&1 && candidates+=("$(command -v python3)")
  for p in "${candidates[@]}"; do
    [ -n "$p" ] && [ -x "$p" ] || continue
    if "$p" -c "import ruamel.yaml" >/dev/null 2>&1 || "$p" -c "import yaml" >/dev/null 2>&1; then
      echo "$p"
      return 0
    fi
  done
  return 0
}

build_events_json() {
  local arr='[]' ev cmd
  for ev in $HERMES_EVENTS; do
    cmd="${SHIM} hook ${ev}"
    arr="$(jq -c --arg ev "$ev" --arg cmd "$cmd" '. + [{event: $ev, command: $cmd, timeout: 10}]' <<<"$arr")"
  done
  # Context injection: a second pre_llm_call entry that returns atrium's
  # manifest + pane-rename nudge as {"context": ...} (Hermes appends it to the
  # turn). Runs alongside the activity pre_llm_call entry; Hermes aggregates.
  arr="$(jq -c --arg cmd "${SHIM} inject" '. + [{event: "pre_llm_call", command: $cmd, timeout: 15}]' <<<"$arr")"
  printf '%s' "$arr"
}

do_install() {
  local py
  py="$(resolve_python)"
  if [ -z "$py" ]; then
    echo '{"error": "no python3 with ruamel.yaml or pyyaml found"}' >&2
    exit 1
  fi
  chmod +x "$HOOK_SCRIPT" "$NORMALIZER" "$INJECT_SCRIPT" 2>/dev/null || true
  write_shim

  local events
  events="$(build_events_json)"
  if ! "$py" "$PYHELPER" install "$CONFIG_YAML" "$ALLOWLIST" "$MARKER" "$events"; then
    echo '{"error": "failed to edit config.yaml"}' >&2
    exit 1
  fi
  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  local py
  py="$(resolve_python)"
  if [ -n "$py" ]; then
    "$py" "$PYHELPER" uninstall "$CONFIG_YAML" "$ALLOWLIST" "$MARKER" || true
  fi
  rm -f "$SHIM"
  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  local py
  py="$(resolve_python)"
  if [ -n "$py" ]; then
    "$py" "$PYHELPER" status "$CONFIG_YAML" "$MARKER"
  else
    echo '{"subcommand": "status", "installed": false, "activityHooks": false}'
  fi
}

case "$SUBCOMMAND" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *)
    echo "{\"error\": \"Unknown subcommand: ${SUBCOMMAND}\"}" >&2
    exit 2
    ;;
esac
