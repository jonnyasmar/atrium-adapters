#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Codex hook installation for atrium.
# Codex hooks require TWO config changes:
#   1. Enable `hooks = true` under `[features]` in ~/.codex/config.toml
#      (feature flag; renamed from the deprecated `codex_hooks` key — install
#      migrates the deprecated line to the new key when present)
#   2. Write hook definitions into ~/.codex/hooks.json under .hooks.<Event>
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"
CONFIG_TOML="${HOME}/.codex/config.toml"
HOOKS_JSON="${HOME}/.codex/hooks.json"

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

# Marker embedded as the first statement of every atrium-owned hook command.
# The regex matches both current and legacy command shapes so install and
# uninstall can still clean up entries written by prior releases.
ATRIUM_HOOK_MARKER_PREFIX="ATRIUM_HOOK_MARKER=atrium-runtime-hook"
ATRIUM_HOOK_MARKER_RE='atrium-runtime-hook|atrium hook emit|skills resolve-manifest|skills resolve-prompt-sigils|atrium/hook-port|/resolve|pane-name-check\.sh'

# Event table: kebab-case event name, Codex settings key, matcher.
EVENTS=$'session-start\tSessionStart\tstartup|resume
session-end\tSessionEnd\t*
pre-tool-use\tPreToolUse\t.*
post-tool-use\tPostToolUse\t.*
stop\tStop\t.*
user-prompt-submit\tUserPromptSubmit\t.*'

# Build the hook command string for a given event. Resolved at hook-fire time
# against the pane's injected env vars so stable/dev/beta can coexist. Trails
# with `exit 0` so any CLI failure never breaks the agent session.
#
# Codex 0.120+ strictly parses UserPromptSubmit hook stdout as a JSON envelope
# and reports "hook returned invalid user prompt submit JSON output" when the
# stdout is empty. The atrium CLI suppresses its own stdout (so its status
# object isn't misread as a hook result), so for that event we follow the
# CLI call with a no-op `{}` envelope to satisfy the parser. Other events
# tolerate empty stdout and don't need the trailing emit.
build_hook_command() {
  local event="$1"
  local trailer="exit 0"
  if [ "$event" = "user-prompt-submit" ]; then
    trailer='printf "{}\n"; exit 0'
  fi
  # For `post-tool-use` events, the native payload is piped through
  # `normalize-hook-payload.sh` first so atrium consumes the canonical
  # `_atrium` envelope (see ../../HOOK_ENVELOPE.md). Other events
  # stream straight to `atrium hook emit`. Path is ${ATRIUM_DATA_DIR:-...}
  # so the same hook entry resolves to whichever atrium channel launched
  # the pane.
  local normalizer=""
  if [ "$event" = "post-tool-use" ]; then
    normalizer="\"\${ATRIUM_DATA_DIR:-\$HOME/.atrium}/adapters/codex/normalize-hook-payload.sh\" | "
  fi
  printf '%s; %s"${ATRIUM_CLI_PATH:-atrium}" hook emit %s --adapter codex --pane-id "${ATRIUM_PANE_ID:-}" --json 2>/dev/null; %s' \
    "$ATRIUM_HOOK_MARKER_PREFIX" "$normalizer" "$event" "$trailer"
}

# Assemble the full hooks object by walking the event table, then append the
# codex-specific context-inject entry whose stdout becomes session context.
build_all_hooks() {
  local hooks='{}'
  local event key matcher cmd entry
  while IFS=$'\t' read -r event key matcher; do
    [ -n "${event:-}" ] || continue
    cmd="$(build_hook_command "$event")"
    entry="$(jq -n --arg matcher "$matcher" --arg cmd "$cmd" \
      '[{matcher: $matcher, hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
    hooks="$(jq --arg key "$key" --argjson entry "$entry" \
      '.[$key] = (.[$key] // []) + $entry' <<< "$hooks")"
  done <<< "$EVENTS"

  # Second SessionStart matcher: calls `atrium skills resolve-manifest` at
  # hook-fire time. Stdout (the pane-specific v1 manifest, per-adapter
  # normalized in SkillsHandler::manifest() per NFR18) is consumed as
  # session context by Codex, same as the Claude Code flow.
  local ctx_cmd ctx_entry
  ctx_cmd="$(printf '%s; [ -n "${ATRIUM:-}" ] && "${ATRIUM_CLI_PATH:-atrium}" skills resolve-manifest --pane-id "${ATRIUM_PANE_ID:-}" --adapter codex 2>/dev/null || true' \
    "$ATRIUM_HOOK_MARKER_PREFIX")"
  ctx_entry="$(jq -n --arg cmd "$ctx_cmd" \
    '[{matcher: "startup|resume", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson ctx "$ctx_entry" '.SessionStart += $ctx' <<< "$hooks")"

  # Pane-name nudge: appended to UserPromptSubmit so the agent gets a
  # per-prompt reminder until the pane is renamed off its default
  # launcher name. Resolved at hook-fire time via ${ATRIUM_DATA_DIR:-...}
  # so stable / dev / beta installs on the same machine don't clobber
  # each other's hook entries.
  local rename_cmd rename_entry
  rename_cmd="\${ATRIUM_DATA_DIR:-\$HOME/.atrium}/adapters/shared/pane-name-check.sh codex"
  rename_entry="$(jq -n --arg cmd "$rename_cmd" \
    '[{matcher: ".*", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson r "$rename_entry" '.UserPromptSubmit += $r' <<< "$hooks")"

  # `+name@scope` sigil auto-resolve: appended to UserPromptSubmit so the
  # CLI scans the prompt for sigils, resolves bodies via the registry,
  # and emits `{"hookSpecificOutput": {"additionalContext": <bodies>}}`
  # for Codex to inject as this-turn context. systemMessage is omitted
  # for Codex — its only status primitive is the static per-hook
  # `statusMessage` field, which fires on every prompt regardless of
  # whether sigils were present (silence beats misleading noise). Empty
  # prompts emit `{}\n` (no-op envelope) so Codex 0.120+'s strict JSON
  # parser is satisfied. The `|| true` trailer is NOT needed here
  # because the CLI always exits 0 on NFR8 failure.
  local sigil_cmd sigil_entry
  sigil_cmd="$(printf '%s; [ -n "${ATRIUM:-}" ] && "${ATRIUM_CLI_PATH:-atrium}" skills resolve-prompt-sigils --pane-id "${ATRIUM_PANE_ID:-}" --adapter codex 2>/dev/null || printf "{}\\n"' \
    "$ATRIUM_HOOK_MARKER_PREFIX")"
  sigil_entry="$(jq -n --arg cmd "$sigil_cmd" \
    '[{matcher: ".*", hooks: [{type: "command", command: $cmd, timeout: 5}]}]')"
  hooks="$(jq --argjson s "$sigil_entry" '.UserPromptSubmit += $s' <<< "$hooks")"

  printf '%s' "$hooks"
}

ensure_codex_dir() {
  local dir
  dir="$(dirname "$CONFIG_TOML")"
  [ -d "$dir" ] || mkdir -p "$dir"
}

ensure_hooks_file() {
  ensure_codex_dir
  [ -f "$HOOKS_JSON" ] || echo '{}' > "$HOOKS_JSON"
}

# Enable the hooks feature flag in config.toml. Handles four cases:
# missing file, existing [features] section, no [features] section, and
# legacy `codex_hooks = ...` lines (deprecated in current Codex; we strip
# them so the deprecation warning stops firing).
enable_hooks_feature() {
  ensure_codex_dir

  if [ ! -f "$CONFIG_TOML" ]; then
    printf '[features]\nhooks = true\n' > "$CONFIG_TOML"
    return 0
  fi

  local tmp="${CONFIG_TOML}.atrium-tmp"

  # Drop any legacy `codex_hooks` line so codex no longer warns about it.
  # Done as a first pass so the rest of the function sees a clean file.
  sed '/^[[:space:]]*codex_hooks[[:space:]]*=/d' "$CONFIG_TOML" > "$tmp"

  if grep -qE '^\s*hooks\s*=\s*true' "$tmp" 2>/dev/null; then
    mv "$tmp" "$CONFIG_TOML"
    return 0
  fi

  local tmp2="${CONFIG_TOML}.atrium-tmp2"
  if grep -qE '^\[features\]' "$tmp" 2>/dev/null; then
    if grep -qE '^\s*hooks\s*=' "$tmp" 2>/dev/null; then
      sed 's/^\([[:space:]]*hooks[[:space:]]*=[[:space:]]*\).*/\1true/' "$tmp" > "$tmp2"
    else
      sed '/^\[features\]/a\
hooks = true' "$tmp" > "$tmp2"
    fi
  else
    printf '%s\n\n[features]\nhooks = true\n' "$(cat "$tmp")" > "$tmp2"
  fi
  mv "$tmp2" "$CONFIG_TOML"
  rm -f "$tmp"
}

disable_hooks_feature() {
  [ -f "$CONFIG_TOML" ] || return 0
  if grep -qE '^\s*(codex_hooks|hooks)\s*=' "$CONFIG_TOML" 2>/dev/null; then
    local tmp="${CONFIG_TOML}.atrium-tmp"
    # Flip both legacy `codex_hooks` and current `hooks` to false. Leaving
    # the legacy key behind would re-trigger the deprecation warning, but
    # disable is non-destructive by contract — users who want it gone can
    # delete the line manually.
    sed -E 's/^([[:space:]]*(codex_hooks|hooks)[[:space:]]*=[[:space:]]*).*/\1false/' "$CONFIG_TOML" > "$tmp"
    mv "$tmp" "$CONFIG_TOML"
  fi
}

# Strip [mcp_servers.atrium] / [mcp_servers.atrium.env] blocks from config.toml.
# Legacy cleanup from when atrium shipped an MCP server instead of the CLI skill.
remove_atrium_mcp_config() {
  [ -f "$CONFIG_TOML" ] || return 0
  local tmp="${CONFIG_TOML}.atrium-tmp"
  awk '
    BEGIN { skip = 0 }
    /^\[mcp_servers\.atrium(\.env)?\]$/ { skip = 1; next }
    /^\[/ { if (skip) skip = 0 }
    !skip { print }
  ' "$CONFIG_TOML" > "$tmp"
  mv "$tmp" "$CONFIG_TOML"
}

uninstall_mcp_server() {
  if command -v codex &>/dev/null; then
    codex mcp remove atrium 2>/dev/null || true
  fi
  remove_atrium_mcp_config
}

# Pre-trust every hook in hooks.json by writing [hooks.state."<key>"] entries
# into config.toml. Without this, codex 0.129+ flags every hook as
# "untrusted" on first launch and forces the user through a /hooks review
# loop. The trusted_hash format is sha256 of the canonical-JSON form of a
# NormalizedHookIdentity struct (verified byte-for-byte against codex's own
# Rust implementation in codex-rs/config/src/fingerprint.rs and the test
# fixtures in codex-rs/hooks/src/engine/mod_tests.rs).
#
# Strips any pre-existing [hooks.state.*] sections so a reinstall after a
# hook-command change refreshes the hashes (otherwise codex would report
# the hooks as "modified" and re-prompt for review).
trust_all_hooks() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "atrium hooks: python3 not found, skipping auto-trust" >&2
    return 0
  fi
  python3 - "$HOOKS_JSON" "$CONFIG_TOML" <<'PYEOF'
import hashlib, json, os, re, sys
from pathlib import Path

hooks_path = Path(sys.argv[1])
config_path = Path(sys.argv[2])

# Map atrium's PascalCase event names to codex's snake_case state-key labels.
# `hook_event_key_label` in codex-rs/hooks/src/lib.rs is the source of truth.
EVENT_LABELS = {
    'PreToolUse': 'pre_tool_use',
    'PermissionRequest': 'permission_request',
    'PostToolUse': 'post_tool_use',
    'PreCompact': 'pre_compact',
    'PostCompact': 'post_compact',
    'SessionStart': 'session_start',
    'UserPromptSubmit': 'user_prompt_submit',
    'Stop': 'stop',
}

# Codex hashes the identity *after* normalizing the matcher via
# `matcher_pattern_for_event` (codex-rs/hooks/src/events/common.rs), which
# unconditionally drops the matcher for these two events — they don't have
# tool/session matchers conceptually. If we leave the hooks.json matcher in
# the identity for these events, codex's current_hash diverges from ours and
# the hook gets flagged "Modified" instead of "Trusted".
NO_MATCHER_EVENTS = {'user_prompt_submit', 'stop'}

def compute_hash(label, matcher, command, timeout_sec, status_message):
    # Mirrors NormalizedHookIdentity → toml::Value → serde_json::to_value →
    # canonical_json (recursive key sort) → serde_json::to_vec → sha256.
    # Fields with `Option::None` in Rust are omitted by toml (which can't
    # represent null), so we omit them here too. `status_message` and
    # `matcher` are the only optionals in our shape.
    handler = {"type": "command", "command": command, "async": False}
    if timeout_sec is not None:
        handler["timeout"] = timeout_sec
    if status_message is not None:
        handler["statusMessage"] = status_message
    identity = {"event_name": label, "hooks": [handler]}
    if matcher is not None and label not in NO_MATCHER_EVENTS:
        identity["matcher"] = matcher
    canonical = json.dumps(identity, sort_keys=True, separators=(',', ':'))
    return f"sha256:{hashlib.sha256(canonical.encode()).hexdigest()}"

if not hooks_path.exists():
    sys.exit(0)
data = json.loads(hooks_path.read_text() or '{}')
state_entries = {}
for event_pascal, groups in (data.get('hooks') or {}).items():
    label = EVENT_LABELS.get(event_pascal)
    if not label:
        # Codex doesn't have a SessionEnd event; any keys we don't recognize
        # would never be matched by codex anyway, so skip silently.
        continue
    for gi, group in enumerate(groups or []):
        matcher = group.get('matcher')
        for hi, h in enumerate(group.get('hooks') or []):
            if h.get('type') != 'command':
                continue
            command = h.get('command') or ''
            if not command.strip():
                continue
            t = h.get('timeout')
            timeout_sec = max(1, int(t)) if t is not None else 600
            status_message = h.get('statusMessage')
            key = f"{hooks_path}:{label}:{gi}:{hi}"
            state_entries[key] = compute_hash(
                label, matcher, command, timeout_sec, status_message
            )

# Strip every pre-existing [hooks.state] / [hooks.state."..."] section. We
# rewrite the whole atrium-owned trust block from scratch each install, so
# stale entries (e.g. from a prior install whose hooks have since changed)
# don't accumulate. Lines outside hooks.state are preserved verbatim.
text = config_path.read_text() if config_path.exists() else ''
section_re = re.compile(r'^\s*\[\s*([^\]]+?)\s*\]\s*$')
out, in_state = [], False
for line in text.splitlines():
    m = section_re.match(line)
    if m:
        section = m.group(1).strip()
        # Match `hooks.state` and any subsection `hooks.state.<...>`. The
        # subsection key is dotted/quoted by codex, e.g. hooks.state."..."
        # — startswith covers both forms.
        in_state = section == 'hooks.state' or section.startswith('hooks.state.')
        if in_state:
            continue
    if not in_state:
        out.append(line)
while out and not out[-1].strip():
    out.pop()
text_clean = ('\n'.join(out) + '\n') if out else ''

def toml_quoted_key(s: str) -> str:
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

parts = [text_clean]
if state_entries:
    parts.append('\n')
    for key in sorted(state_entries.keys()):
        parts.append(f'[hooks.state.{toml_quoted_key(key)}]\n')
        parts.append('enabled = true\n')
        parts.append(f'trusted_hash = "{state_entries[key]}"\n')

tmp = config_path.with_suffix(config_path.suffix + '.atrium-tmp')
tmp.write_text(''.join(parts))
tmp.replace(config_path)
print(f"atrium hooks: pre-trusted {len(state_entries)} hook(s)", file=sys.stderr)
PYEOF
}

# Strip every atrium-owned [hooks.state."<HOOKS_JSON>:..."] entry on uninstall.
# We identify ours by the `key_source` prefix (the absolute path to our
# hooks.json). User-managed trust entries for other hooks.json files would
# never match this prefix and stay untouched.
untrust_atrium_hooks() {
  [ -f "$CONFIG_TOML" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  python3 - "$HOOKS_JSON" "$CONFIG_TOML" <<'PYEOF'
import re, sys
from pathlib import Path

hooks_path = Path(sys.argv[1])
config_path = Path(sys.argv[2])
prefix = str(hooks_path)
if not config_path.exists():
    sys.exit(0)
text = config_path.read_text()
section_re = re.compile(r'^\s*\[\s*hooks\.state\.\s*"([^"]+)"\s*\]\s*$')
out, drop = [], False
for line in text.splitlines():
    m = section_re.match(line)
    if m:
        drop = m.group(1).startswith(prefix)
        if drop:
            continue
    elif drop and re.match(r'^\s*\[', line):
        drop = False
    if not drop:
        out.append(line)
while out and not out[-1].strip():
    out.pop()
content = ('\n'.join(out) + '\n') if out else ''
tmp = config_path.with_suffix(config_path.suffix + '.atrium-tmp')
tmp.write_text(content)
tmp.replace(config_path)
PYEOF
}

has_atrium_hooks_in() {
  local keys_json
  keys_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  jq -r \
    --argjson keys "$keys_json" \
    --arg marker "$ATRIUM_HOOK_MARKER_RE" \
    '[$keys[] as $k | (.hooks[$k] // [])[] | .hooks[]?.command] | any(test($marker))' \
    "$HOOKS_JSON" 2>/dev/null || echo "false"
}

do_install() {
  enable_hooks_feature
  ensure_hooks_file

  local new_hooks
  new_hooks="$(build_all_hooks)"

  # Deep-merge atrium hooks under the .hooks wrapper. Also strip legacy
  # root-level SessionStart/SessionEnd/on_user_prompt keys that older
  # releases wrote before the wrapper was introduced.
  local updated
  updated="$(jq \
    --argjson new_hooks "$new_hooks" \
    --arg marker "$ATRIUM_HOOK_MARKER_RE" \
    '
    .hooks = (.hooks // {}) |
    reduce ($new_hooks | keys_unsorted[]) as $k (.;
      .hooks[$k] = (
        [(.hooks[$k] // [])[] | select(.hooks | all(.command | test($marker) | not))]
        + $new_hooks[$k]
      )
    )
    | del(.SessionStart, .SessionEnd, .on_user_prompt)
    ' "$HOOKS_JSON")"

  local tmp="${HOOKS_JSON}.atrium-tmp"
  printf '%s\n' "$updated" > "$tmp"
  mv "$tmp" "$HOOKS_JSON"

  uninstall_mcp_server
  trust_all_hooks

  echo '{"subcommand": "install", "installed": true}'
}

do_uninstall() {
  disable_hooks_feature
  untrust_atrium_hooks

  if [ ! -f "$HOOKS_JSON" ]; then
    uninstall_mcp_server
    echo '{"subcommand": "uninstall", "uninstalled": true}'
    return
  fi

  local updated
  updated="$(jq \
    --arg marker "$ATRIUM_HOOK_MARKER_RE" \
    '
    if .hooks then
      .hooks |= with_entries(
        .value |= map(
          .hooks |= map(select(.command | test($marker) | not))
          | select(.hooks | length > 0)
        )
        | select(.value | length > 0)
      )
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
    | del(.SessionStart, .SessionEnd, .on_user_prompt)
    ' "$HOOKS_JSON")"

  local tmp="${HOOKS_JSON}.atrium-tmp"
  printf '%s\n' "$updated" > "$tmp"
  mv "$tmp" "$HOOKS_JSON"

  uninstall_mcp_server

  echo '{"subcommand": "uninstall", "uninstalled": true}'
}

do_status() {
  # Session is installed iff the feature flag is enabled AND both
  # SessionStart and SessionEnd carry atrium hooks.
  local has_feature=false
  if [ -f "$CONFIG_TOML" ] && grep -qE '^\s*(codex_hooks|hooks)\s*=\s*true' "$CONFIG_TOML" 2>/dev/null; then
    has_feature=true
  fi

  local session="false" activity="false"
  if [ -f "$HOOKS_JSON" ]; then
    local start end
    start="$(has_atrium_hooks_in SessionStart)"
    end="$(has_atrium_hooks_in SessionEnd)"
    if [ "$start" = "true" ] && [ "$end" = "true" ]; then
      session="true"
    fi
    activity="$(has_atrium_hooks_in PreToolUse PostToolUse Stop UserPromptSubmit)"
  fi

  local installed="false"
  if [ "$has_feature" = "true" ] && [ "$session" = "true" ]; then
    installed="true"
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
