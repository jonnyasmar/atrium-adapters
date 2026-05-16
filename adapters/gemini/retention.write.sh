#!/usr/bin/env bash
set -euo pipefail

# Writes Gemini CLI's session retention setting. Atrium invokes this from
# the retention modal: each retention field is passed as a positional
# `key=value` arg. For gemini we accept:
#   - `days=<int>`     → serialized as `general.sessionRetention.maxAge = "<int>d"`
#   - `maxCount=<int>` → serialized as `general.sessionRetention.maxCount = <int>`
#
# Output schema on success: {"ok": true}
# Output schema on error:   non-zero exit + error message on stderr
#
# Writes are atomic: render to a temp file in the same directory, `mv` over
# the original. Missing settings.json is treated as "fresh install" — we
# create one with just the retention block.

SETTINGS="${HOME}/.gemini/settings.json"

new_days=""
new_max_count=""

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
    maxCount=*)
      val="${arg#maxCount=}"
      if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "retention.write.sh: invalid value for 'maxCount': '$val'" >&2
        exit 2
      fi
      new_max_count="$val"
      ;;
    *)
      echo "retention.write.sh: unknown field '${arg%%=*}' (expected 'days=<int>' or 'maxCount=<int>')" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$new_days" || -z "$new_max_count" ]]; then
  echo "retention.write.sh: missing required fields (need 'days=<int>' and 'maxCount=<int>')" >&2
  exit 2
fi

mkdir -p "$(dirname "$SETTINGS")"
max_age="${new_days}d"

if [[ -f "$SETTINGS" ]]; then
  tmp="$(mktemp "${SETTINGS}.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  jq \
    --arg age "$max_age" \
    --argjson mc "$new_max_count" \
    '.general = (.general // {})
     | .general.sessionRetention = (.general.sessionRetention // {})
     | .general.sessionRetention.enabled = true
     | .general.sessionRetention.maxAge = $age
     | .general.sessionRetention.maxCount = $mc' \
    "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  trap - EXIT
else
  jq -n \
    --arg age "$max_age" \
    --argjson mc "$new_max_count" \
    '{"general": {"sessionRetention": {"enabled": true, "maxAge": $age, "maxCount": $mc}}}' \
    > "$SETTINGS"
fi

printf '{"ok":true}\n'
