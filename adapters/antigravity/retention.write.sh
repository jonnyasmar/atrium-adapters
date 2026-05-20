#!/usr/bin/env bash
set -euo pipefail

# Writes Antigravity CLI's session retention setting under
# `general.sessionRetention` in ~/.gemini/antigravity-cli/settings.json.
# Mirrors gemini's contract:
#   - `days=<int>`     → serialized as `general.sessionRetention.maxAge = "<int>d"`
#   - `maxCount=<int>` → serialized as `general.sessionRetention.maxCount = <int>`

SETTINGS="${HOME}/.gemini/antigravity-cli/settings.json"

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
