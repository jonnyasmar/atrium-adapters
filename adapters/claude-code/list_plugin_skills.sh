#!/usr/bin/env bash
set -euo pipefail

# list_plugin_skills.sh — resolve Claude Code *plugin* skill roots.
#
# Claude Code installs plugin skills under
#   ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/<skill>/SKILL.md
# a tree atrium's normal `skillsDir` (~/.claude/skills) scan never
# reaches. This reports the active, ENABLED plugins' skill roots so
# atrium core can fold them into the Claude Code harness view (each
# skill filed as `<namespace>:<skill>`).
#
# Output (stdout, JSON):
#   {
#     "scopes": [ { "dir": "<abs .../skills>", "namespace": "<plugin>" }, ... ],
#     "watch":  [ "<abs installed_plugins.json>", "<abs settings.json>" ]
#   }
#
# `dir`s need not exist — atrium skips missing scopes — so we never stat
# per candidate (single jq pass, no per-plugin subprocess loop; well
# under the <50ms adapter-script budget). A plugin is included unless
# `settings.json`'s `enabledPlugins[<key>]` is explicitly `false`.
# `namespace` is the plugin id (the registry key before `@`).
#
# `watch` is always reported (even with zero plugins) so atrium arms its
# watcher and picks up the very first install without a relaunch.

INSTALLED="${HOME}/.claude/plugins/installed_plugins.json"
SETTINGS="${HOME}/.claude/settings.json"

WATCH_JSON="$(jq -nc --arg a "$INSTALLED" --arg b "$SETTINGS" '[$a, $b]')"

if [ ! -f "$INSTALLED" ]; then
  printf '{"scopes":[],"watch":%s}\n' "$WATCH_JSON"
  exit 0
fi

ENABLED='{}'
if [ -f "$SETTINGS" ]; then
  ENABLED="$(jq -c '.enabledPlugins // {}' "$SETTINGS" 2>/dev/null || echo '{}')"
fi

SCOPES="$(jq -c --argjson enabled "$ENABLED" '
  [ (.plugins // {}) | to_entries[]
    | .key as $k
    | ($k | split("@")[0]) as $ns
    | (.value[0].installPath // "") as $ip
    | select($ip != "")
    | select(($enabled[$k]) != false)
    | { namespace: $ns, dir: ($ip + "/skills") }
  ]
' "$INSTALLED")"

printf '{"scopes":%s,"watch":%s}\n' "$SCOPES" "$WATCH_JSON"
