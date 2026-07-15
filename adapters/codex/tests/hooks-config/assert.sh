#!/usr/bin/env bash
set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS_SH="$ADAPTER_DIR/hooks.sh"
TEST_HOME="$(mktemp -d /tmp/atrium-codex-hooks.XXXXXX)"
trap 'rm -rf "$TEST_HOME"' EXIT

mkdir -p "$TEST_HOME/.codex" "$TEST_HOME/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_HOME/bin/codex"
chmod +x "$TEST_HOME/bin/codex"

printf '%s\n' \
  '[features]' \
  'hooks = false' \
  'shell_tool = true' \
  '' \
  '[projects."/tmp/example"]' \
  'trust_level = "trusted"' \
  '' \
  '[features]' \
  'hooks = true' \
  'shell_tool = false' \
  'web_search = true' \
  > "$TEST_HOME/.codex/config.toml"
printf '{}\n' > "$TEST_HOME/.codex/hooks.json"

pids=()
for index in 1 2 3 4; do
  HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" \
    "$HOOKS_SH" install > "$TEST_HOME/install-$index.out" 2> "$TEST_HOME/install-$index.err" &
  pids+=("$!")
done

for pid in "${pids[@]}"; do
  wait "$pid"
done

CONFIG_TOML="$TEST_HOME/.codex/config.toml"
HOOKS_JSON="$TEST_HOME/.codex/hooks.json"

feature_count="$(awk '$0 == "[features]" { count++ } END { print count + 0 }' "$CONFIG_TOML")"
[ "$feature_count" -eq 1 ] || {
  echo "expected one [features] table after concurrent installs, found $feature_count" >&2
  exit 1
}

hook_count="$(grep -cE '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$CONFIG_TOML" || true)"
[ "$hook_count" -eq 1 ] || {
  echo "expected one enabled hooks flag after concurrent installs, found $hook_count" >&2
  exit 1
}

[ "$(grep -c '^shell_tool = ' "$CONFIG_TOML" || true)" -eq 1 ]
grep -q '^web_search = true$' "$CONFIG_TOML"
grep -q '^\[projects."/tmp/example"\]$' "$CONFIG_TOML"
jq -e '.hooks.SessionStart and .hooks.SessionEnd' "$HOOKS_JSON" >/dev/null

printf '999999\n' > "$TEST_HOME/.codex/.atrium-hooks.lock"
HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" "$HOOKS_SH" install >/dev/null
[ ! -e "$TEST_HOME/.codex/.atrium-hooks.lock" ]

if find "$TEST_HOME/.codex" -maxdepth 1 -name '*.atrium-tmp.*' -print -quit | grep -q .; then
  echo "temporary Codex config files were left behind" >&2
  exit 1
fi

echo "[PASS] duplicate feature normalization and concurrent installs"
