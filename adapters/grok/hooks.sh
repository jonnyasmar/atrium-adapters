#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Grok hook installation for atrium.
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr
#
# Grok's hook discovery (per `xai_grok_hooks::discovery`) loads from:
#   1. ~/.grok/hooks/*.json           — user scope, always trusted
#   2. ~/.claude/settings.json        — Claude Code compatibility
#   3. <project>/.grok/hooks/*.json   — project scope, requires trust
#   4. <project>/.claude/settings.json — Claude Code compatibility
#
# Plugin-bundled hooks (`installed-plugins/<name>/hooks/hooks.json`)
# are NOT loaded by the hook dispatcher in v0 — they're indexed for
# `grok inspect` display but never fired. We therefore install at the
# user-scope path `~/.grok/hooks/atrium-grok.json` instead, where
# every event reliably dispatches.

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

HOOKS_DIR="${HOME}/.grok/hooks"
HOOKS_FILE="${HOOKS_DIR}/atrium-grok.json"

ATRIUM_HOOK_MARKER_PREFIX="ATRIUM_HOOK_MARKER=atrium-runtime-hook"
ATRIUM_HOOK_MARKER_RE='atrium-runtime-hook|atrium hook emit|skills resolve-manifest|skills resolve-prompt-sigils|atrium/hook-port|/resolve|pane-name-check\.sh'

# Channel discovery — bake the right CLI fallback path into hook
# commands so dev/stable installs don't clobber each other. The probe
# inspects the running script's own location so a single machine with
# both dev and stable installed gets the matching CLI for each install.
# The `${ATRIUM_CLI_PATH:-…}` shell substitution at hook-fire time
# still wins whenever the pane env injects it.
SCRIPT_DIR_REAL="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P || echo "")"
if [ "${SCRIPT_DIR_REAL#${HOME}/.atrium-dev}" != "$SCRIPT_DIR_REAL" ]; then
  ATRIUM_CLI_FALLBACK="${HOME}/.atrium-dev/bin/atrium-dev"
else
  ATRIUM_CLI_FALLBACK="${HOME}/.atrium/bin/atrium"
fi

# Adapter dir — where normalize-hook-payload.sh lives. Resolved at
# hook-fire time so the same hook entry works for stable/dev/beta.
NORMALIZER_REF='"${ATRIUM_DATA_DIR:-$HOME/.atrium}/adapters/grok/normalize-hook-payload.sh"'

# Event table: atrium event name → grok hook event key → matcher.
#
# Matcher field MUST be omitted for grok v0 lifecycle hooks. Per the
# grok runtime, `xai_grok_hooks::config` warns and drops any entry on
# SessionStart / SessionEnd / UserPromptSubmit / Stop / Notification /
# SubagentStop that specifies a matcher (even an empty string). Only
# Pre/PostToolUse accept a matcher (matched against the tool name);
# we omit there too for consistency with the reference plugin shape
# (hookify, example-plugin).
EVENTS=$'session-start\tSessionStart\t
session-end\tSessionEnd\t
pre-tool-use\tPreToolUse\t
post-tool-use\tPostToolUse\t
post-tool-use-failure\tPostToolUseFailure\t
stop\tStop\t
stop-failure\tStopFailure\t
notification\tNotification\t
user-prompt-submit\tUserPromptSubmit\t
subagent-start\tSubagentStart\t
subagent-stop\tSubagentStop\t'

# Build the hook command string for a given event. EVERY event is
# piped through normalize-hook-payload.sh — grok emits camelCase
# (`sessionId`, `toolName`, `toolInput`, `prompt`, …) and atrium's
# activity-card reducer reads snake_case, so the remap is required
# for the card to render tool calls + prompts at all. Trails with
# `exit 0` so any CLI failure never blocks grok's tool/turn lifecycle.
#
# PostToolUseFailure has no atrium-side event of its own — normalize
# enriches it with `error` and we re-emit as `post-tool-use` so failed
# tools show on the activity card instead of vanishing.
build_hook_command() {
  local event="$1"
  local emit_event="$event"
  if [ "$event" = "post-tool-use-failure" ]; then
    emit_event="post-tool-use"
  fi
  printf '%s; %s %s | "${ATRIUM_CLI_PATH:-%s}" hook emit %s --adapter grok --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null; exit 0' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$NORMALIZER_REF" "$event" "$ATRIUM_CLI_FALLBACK" "$emit_event"
}

# Build the plugin's hooks/hooks.json content.
build_hooks_json() {
  local hooks='{}'
  local event key matcher cmd entry
  while IFS=$'\t' read -r event key matcher; do
    [ -n "${event:-}" ] || continue
    cmd="$(build_hook_command "$event")"
    if [ -n "$matcher" ]; then
      entry="$(jq -n --arg matcher "$matcher" --arg cmd "$cmd" \
        '[{matcher: $matcher, hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
    else
      entry="$(jq -n --arg cmd "$cmd" \
        '[{hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
    fi
    hooks="$(jq --arg key "$key" --argjson entry "$entry" \
      '.[$key] = (.[$key] // []) + $entry' <<< "$hooks")"
  done <<< "$EVENTS"

  # NO hook-based context-injection wiring (pane-rename nudge / sigils /
  # manifest). Grok only consumes stdout from BLOCKING hooks (PreToolUse,
  # for the allow/deny decision); ALL other hooks are "passive" and their
  # stdout is ignored (per ~/.grok/docs/user-guide/10-hooks.md "Passive
  # Hooks" + a live `grok -p` probe where an injected UserPromptSubmit
  # additionalContext directive was NOT obeyed, 2026-06-04). So
  # `pane-name-check.sh`, `skills resolve-prompt-sigils`, and `skills
  # resolve-manifest` would all produce output grok throws away — wiring
  # them just burns a CLI call per prompt.
  #
  # Fallback (v0.4.0+): build_launch_command.sh / build_resume_command.sh
  # append atrium-context + a static pane-rename instruction via
  # `grok --rules` (see atrium-session-rules.sh). That covers session
  # orientation; live per-turn rename nags and same-turn sigil injection
  # remain unavailable. If a future grok adds additionalContext support
  # for UserPromptSubmit/SessionStart, re-add the wiring + flip
  # hookEnvelopes back to hookSpecificOutput/identity.
  jq -n --argjson hooks "$hooks" \
    '{description: "atrium-grok hook bridge", hooks: $hooks}'
}

do_install() {
  mkdir -p "$HOOKS_DIR"
  build_hooks_json > "$HOOKS_FILE.atrium-tmp"
  mv "$HOOKS_FILE.atrium-tmp" "$HOOKS_FILE"

  # Sweep up the legacy plugin install (atrium 0.1.0 shipped the plugin
  # variant before we discovered grok's plugin hooks aren't dispatched).
  local legacy="${HOME}/.grok/installed-plugins/atrium-grok-atrium"
  local registry="${HOME}/.grok/installed-plugins/registry.json"
  if [ -d "$legacy" ]; then
    rm -rf "$legacy"
  fi
  if [ -f "$registry" ]; then
    local updated tmp
    updated="$(jq 'del(.repos["atrium-grok-atrium"])' "$registry" 2>/dev/null || cat "$registry")"
    tmp="${registry}.atrium-tmp"
    printf '%s\n' "$updated" > "$tmp"
    mv "$tmp" "$registry"
  fi
  # Drop the stale config.toml `enabled` entry that referenced the legacy plugin.
  if [ -f "${HOME}/.grok/config.toml" ]; then
    sed -i '' '/"atrium-grok",/d; /"atrium-probe",/d' "${HOME}/.grok/config.toml" 2>/dev/null || true
  fi

  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  if [ -f "$HOOKS_FILE" ]; then
    rm -f "$HOOKS_FILE"
  fi

  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  local installed=false
  local activity=false

  if [ -f "$HOOKS_FILE" ]; then
    installed=true
    if jq -e \
      --arg marker "$ATRIUM_HOOK_MARKER_RE" \
      '[.hooks.PreToolUse[0].hooks[]?.command, .hooks.PostToolUse[0].hooks[]?.command, .hooks.Stop[0].hooks[]?.command, .hooks.UserPromptSubmit[0].hooks[]?.command]
       | map(select(. != null))
       | any(test($marker))' "$HOOKS_FILE" >/dev/null 2>&1; then
      activity=true
    fi
  fi

  echo "{\"subcommand\": \"status\", \"installed\": ${installed}, \"activityHooks\": ${activity}}"
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
