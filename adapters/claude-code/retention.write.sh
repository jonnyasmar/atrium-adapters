#!/usr/bin/env bash
set -euo pipefail

# Writes Claude Code's session retention setting. Atrium invokes this from
# the retention modal: each retention field is passed as a positional
# `key=value` arg. For claude-code we accept a single `days=<int>` pair.
#
# Output schema on success: {"ok": true}
# Output schema on error:   non-zero exit + error message on stderr
#
# Writes are atomic: we render the new JSON to a temp file in the same
# directory and `mv` it over the original. Missing settings.json is treated
# as "fresh install" — we create one with just `cleanupPeriodDays`.

SETTINGS="${HOME}/.claude/settings.json"

new_days=""

for arg in "$@"; do
  case "$arg" in
    days=*)
      val="${arg#days=}"
      if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "retention.write.sh: invalid value for 'days': '$val'" >&2
        exit 2
      fi
      new_days="$val"
      ;;
    *)
      echo "retention.write.sh: unknown field '${arg%%=*}' (expected 'days=<int>')" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$new_days" ]]; then
  echo "retention.write.sh: missing required field 'days=<int>'" >&2
  exit 2
fi

mkdir -p "$(dirname "$SETTINGS")"

if [[ -f "$SETTINGS" ]]; then
  tmp="$(mktemp "${SETTINGS}.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  jq --argjson d "$new_days" '.cleanupPeriodDays = $d' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  trap - EXIT
else
  printf '{\n  "cleanupPeriodDays": %d\n}\n' "$new_days" > "$SETTINGS"
fi

printf '{"ok":true}\n'
