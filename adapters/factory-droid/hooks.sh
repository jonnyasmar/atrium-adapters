#!/usr/bin/env bash
set -euo pipefail

# hooks.sh — Manage Factory Droid hook installation for atrium.
# Subcommands: install, uninstall, status
# Output: JSON to stdout, diagnostics to stderr
#
# Droid reads lifecycle hooks from ~/.factory/hooks.json (user scope).
# Events: SessionStart, SessionEnd, PreToolUse, PostToolUse, Stop,
# UserPromptSubmit, Notification, SubagentStop, PreCompact.
#
# Note: droid's hook dispatcher runs for interactive sessions. In
# `exec --output-format acp` (the mode atrium's chat pane uses with
# droid 0.189.x) droid does not fire lifecycle hooks, so chat-pane
# activity is tracked by atrium over the ACP transport instead. The
# hooks below still follow the standard atrium adapter contract: every
# command is guarded so it only emits inside a real atrium pane, and
# droid's hook stdin (snake_case fields) passes straight through to
# `atrium hook emit`.

SUBCOMMAND="${1:?Usage: hooks.sh <install|uninstall|status>}"

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required for hook management"}' >&2
  exit 1
fi

HOOKS_FILE="${HOME}/.factory/hooks.json"

case "$SUBCOMMAND" in
  install)
    python3 - "$HOOKS_FILE" <<'PY'
import json, os, sys
path = sys.argv[1]
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
else:
    data = {"hooks": {}}
hooks = data.setdefault("hooks", {})
events = {
    "SessionStart": "session-start",
    "SessionEnd": "session-end",
    "PreToolUse": "pre-tool-use",
    "PostToolUse": "post-tool-use",
    "Stop": "stop",
    "UserPromptSubmit": "user-prompt-submit",
    "Notification": "notification",
    "SubagentStop": "subagent-stop",
}
marker = "ATRIUM_HOOK_MARKER=atrium-runtime-hook"
changed = False
for droid_event, atrium_event in events.items():
    groups = hooks.get(droid_event, [])
    already = False
    for g in groups:
        cmds = ", ".join(h.get("command", "") for h in g.get("hooks", []))
        if marker in cmds:
            already = True
            break
    if already:
        continue
    cmd = ("%s; [ -z \"${ATRIUM:-}\" ] && exit 0; \"${ATRIUM_CLI_PATH:-$HOME/.atrium/bin/atrium}\" "
           "hook emit %s --adapter factory-droid --pane-id \"${ATRIUM_PANE_ID:-}\" --json 2>/dev/null; exit 0"
           % (marker, atrium_event))
    groups.append({"hooks": [{"type": "command", "command": cmd, "timeout": 5}]})
    hooks[droid_event] = groups
    changed = True
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
os.chmod(path, 0o600)
print('{"subcommand": "install", "installed": true}')
PY
    ;;

  uninstall)
    python3 - "$HOOKS_FILE" <<'PY'
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    print('{"subcommand": "uninstall", "uninstalled": true}')
    sys.exit(0)
with open(path) as f:
    data = json.load(f)
hooks = data.get("hooks", {})
marker = "atrium-runtime-hook"
changed = False
for event in list(hooks.keys()):
    groups = [g for g in hooks[event] if marker not in ", ".join(h.get("command", "") for h in g.get("hooks", []))]
    if len(groups) != len(hooks[event]):
        changed = True
    if groups:
        hooks[event] = groups
    else:
        del hooks[event]
if not hooks:
    data.pop("hooks", None)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print('{"subcommand": "uninstall", "uninstalled": true}')
PY
    ;;

  status)
    if [ -f "$HOOKS_FILE" ] && grep -q "atrium-runtime-hook" "$HOOKS_FILE"; then
      echo '{"subcommand": "status", "installed": true}'
    else
      echo '{"subcommand": "status", "installed": false, "reason": "Droid hooks are not registered in ~/.factory/hooks.json. Run hooks.sh install or use Repair hooks."}'
    fi
    ;;

  *)
    echo "Unknown subcommand: $SUBCOMMAND" >&2
    exit 2
    ;;
esac
