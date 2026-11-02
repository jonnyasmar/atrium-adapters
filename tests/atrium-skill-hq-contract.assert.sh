#!/usr/bin/env bash
# atrium's director and staff rules (atrium-agent-catalog director_rules.rs,
# staff_rules.rs) name each HQ command and leave its flags and formats to the
# atrium skill's references/hq.md. This pins that the reference carries them,
# that SKILL.md points at it, and that it ships.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ref="$ROOT/skills/atrium/references/hq.md"
skill="$ROOT/skills/atrium/SKILL.md"

fail() {
  echo "atrium skill HQ contract: $1" >&2
  exit 1
}

require() { # <file> <fixed string> <message>
  grep -Fq -- "$2" "$1" || fail "$3"
}

[ -f "$ref" ] || fail "references/hq.md is missing"
require "$skill" 'references/hq.md' 'SKILL.md must point at references/hq.md'

for flag in \
  'task delegate --title' '--brief' '--to <staff-slug>' '--workspace' \
  'hq hire <name> --description' '--instructions' '--adapter <name>' '--skill' \
  'hq let-go' 'hq bring-back' \
  'routine create --title' '--prompt' '--self' '--agent <staff-slug>' '--cron' '--every' '--at' '--in' '--done-when' 'routine done <card>' \
  'label create' '--icon' '--color' '--guidance' 'hq label <label>' \
  'atrium-short-name=' "--description \"<one-line role>\"" "atrium-dock=<json>" \
  '{"tabs":[...],"hidden":[...]}' '{"kind":"pane","paneId":"…"}' '{"kind":"note","workspaceId":"…","noteId":"…"}' '"browser"' \
  'attached items, listed in the Overview' \
  'memory remember "<fact>" --pin' 'hq adopt <pane>' 'hq unfollow <pane>' \
  'hq chats' 'hq chats read <main|id> [--lines N]' \
  'secret request <NAME> --kind env|login|secret --why' '--site' 'secret run --env <NAME>' \
  'browser fill-login <pane|mine> <login>' 'browser hand-off' '--pane <pane|mine>' '--done-when-url'; do
  require "$ref" "$flag" "references/hq.md lost $flag"
done

jq -e '.references | index("hq.md")' "$ROOT/skills/atrium/skill-assets.json" >/dev/null \
  || fail 'skill-assets.json must list hq.md'
jq -e '.assets[] | select(.remotePath == "skills/atrium/references/hq.md" and .target == "adapter-skill-reference" and .destName == "hq.md")' \
  "$ROOT/canonical-assets.json" >/dev/null || fail 'canonical-assets.json must ship hq.md'

echo "atrium skill HQ contract: ok"
