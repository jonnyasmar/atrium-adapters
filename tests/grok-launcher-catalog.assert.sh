#!/usr/bin/env bash
set -euo pipefail

# Grok launcher_options must match the live CLI catalog (grok 1.0.5 /
# ~/.grok/models_cache.json): grok-4.6 + grok-4.5, per-model efforts,
# no SKUs that are agent types or retired composer ids, no effort `max`.
# Atrium caches static launcher_options at adapter load — do not replace
# this file with a script until the host executes that method.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${ROOT}/adapters/grok/launcher_options.json"

if [[ ! -f "$FILE" ]]; then
  printf '[FAIL] missing %s\n' "$FILE"
  exit 1
fi

if ! jq empty "$FILE" >/dev/null 2>&1; then
  printf '[FAIL] %s is not valid JSON\n' "$FILE"
  exit 1
fi

diff_out="$(jq -e '
  (.options | map(select(.key == "model")) | .[0]) as $model
  | (.options | map(select(.key == "effort")) | .[0]) as $effort
  | [
      if ($model.choices | map(.value)) == ["grok-4.6", "grok-4.5"] then empty
      else {path: "model.choices.values", expected: ["grok-4.6", "grok-4.5"], actual: ($model.choices | map(.value))} end,
      if ($model.choices | any(.value == "grok-build" or .value == "grok-composer-2.5-fast")) then
        {path: "model.choices", expected: "no grok-build / grok-composer-2.5-fast", actual: ($model.choices | map(.value))}
      else empty end,
      if ($model.choices[] | select(.value == "grok-4.6") | .efforts) == ["low", "medium", "high", "xhigh"] then empty
      else {path: "grok-4.6.efforts", expected: ["low", "medium", "high", "xhigh"], actual: ($model.choices[] | select(.value == "grok-4.6") | .efforts)} end,
      if ($model.choices[] | select(.value == "grok-4.5") | .efforts) == ["low", "medium", "high"] then empty
      else {path: "grok-4.5.efforts", expected: ["low", "medium", "high"], actual: ($model.choices[] | select(.value == "grok-4.5") | .efforts)} end,
      if $effort.default == "high" then empty
      else {path: "effort.default", expected: "high", actual: $effort.default} end,
      if $effort.choices == ["low", "medium", "high", "xhigh"] then empty
      else {path: "effort.choices", expected: ["low", "medium", "high", "xhigh"], actual: $effort.choices} end,
      if ($effort.choices | index("max")) == null then empty
      else {path: "effort.choices", expected: "no max", actual: $effort.choices} end
    ]
' "$FILE")"

if [[ "$diff_out" == "[]" ]]; then
  printf '[PASS] grok launcher_options match the live CLI catalog\n'
else
  printf '[FAIL] grok launcher_options diverge from the live CLI catalog\n'
  printf '%s\n' "$diff_out"
  exit 1
fi

# Schema must accept per-model efforts (Claude/Codex/Kimi already ship them).
if python3 -c 'import jsonschema' >/dev/null 2>&1; then
  python3 - "$ROOT" <<'PY'
import json, sys
from pathlib import Path
from jsonschema import Draft202012Validator

root = Path(sys.argv[1])
schema = json.loads((root / "schemas/methods/launcher_options.schema.json").read_text())
payload = json.loads((root / "adapters/grok/launcher_options.json").read_text())
errors = sorted(Draft202012Validator(schema).iter_errors(payload), key=lambda e: list(e.path))
if errors:
    print("[FAIL] grok launcher_options.json does not match launcher_options.schema.json")
    for err in errors:
        loc = "/".join(str(p) for p in err.path) or "<root>"
        print(f"  at {loc}: {err.message}")
    sys.exit(1)
print("[PASS] grok launcher_options.json matches launcher_options.schema.json")
PY
else
  if [[ "${CI:-}" == "true" ]]; then
    printf '[FAIL] jsonschema is required in CI to prove Choice.efforts is in schema\n'
    exit 1
  fi
  printf '[SKIP] jsonschema not installed; grok schema check not run\n'
fi

# Launch argv must still forward catalog model/effort values (no rewrite).
{
  script="${ROOT}/adapters/grok/build_launch_command.sh"
  wrapper="$(cd "$(dirname "${ROOT}/adapters/grok/grok-with-atrium-rules.sh")" && pwd)/grok-with-atrium-rules.sh"
  actual="$(bash "$script" '{"alwaysApprove":true,"model":"grok-4.6","effort":"xhigh"}')"
  cmd="$(echo "$actual" | jq -c '.command')"
  expected="$(jq -nc --arg w "$wrapper" \
    '["env","GROK_DISABLE_AUTOUPDATER=1",$w,"--always-approve","--model","grok-4.6","--reasoning-effort","xhigh"]')"
  if [[ "$cmd" == "$expected" ]]; then
    printf '[PASS] grok launch forwards catalog model/effort flags\n'
  else
    printf '[FAIL] grok launch command mismatch\n'
    printf '  expected: %s\n' "$expected"
    printf '  actual:   %s\n' "$cmd"
    exit 1
  fi
}
