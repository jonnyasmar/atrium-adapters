#!/usr/bin/env bash
set -euo pipefail

# kimi has no --trust flag and its "Trust this folder?" prompt preselects
# "Don't trust — Exit Kimi Code", so an unattended pane launch quits on the
# first Enter. The `trust` launcher toggle prefixes the launch/resume argv with
# trust-workspace.sh, which writes the record kimi's WorkspaceTrustService reads
# (presence of the file == trusted).
#
# Pins two things the gate depends on:
#   1. the wrapper only appears when `trust` is on (it enables the folder's
#      project-level MCP servers, so it must never be implicit)
#   2. the record path matches kimi's encodeWorkDirKey exactly —
#      wd_<slugified basename, 40 chars>_<sha256(resolved dir)[:12]>

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMI_DIR="${ROOT}/adapters/kimi"
TRUST_SH="${KIMI_DIR}/trust-workspace.sh"
FAILURES=0

check() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "[PASS] $label"
  else
    echo "[FAIL] $label"
    echo "       expected: $expected"
    echo "       actual:   $actual"
    FAILURES=$((FAILURES + 1))
  fi
}

argv() { echo "$1" | jq -c '.command'; }

# 1. Off by default, and off when explicitly false.
check "launch: no wrapper by default" \
  "$(argv "$(bash "$KIMI_DIR/build_launch_command.sh" '{}')")" \
  '["kimi"]'
check "launch: no wrapper when trust=false" \
  "$(argv "$(bash "$KIMI_DIR/build_launch_command.sh" '{"trust":false}')")" \
  '["kimi"]'

# 2. On when asked — and ahead of the `env` prefix, so it execs the whole chain.
check "launch: wrapper leads the argv" \
  "$(argv "$(bash "$KIMI_DIR/build_launch_command.sh" \
    '{"trust":true,"effort":"high","permissionMode":"yolo"}')")" \
  "$(jq -cn --arg s "$TRUST_SH" \
    '[$s,"env","KIMI_MODEL_THINKING_EFFORT=high","kimi","--auto"]')"

check "resume: wrapper leads the argv" \
  "$(argv "$(bash "$KIMI_DIR/build_resume_command.sh" sess-1 '{"trust":true}')")" \
  "$(jq -cn --arg s "$TRUST_SH" '[$s,"kimi","--session","sess-1"]')"
check "resume: no wrapper by default" \
  "$(argv "$(bash "$KIMI_DIR/build_resume_command.sh" sess-1 '{}')")" \
  '["kimi","--session","sess-1"]'

# 3. The record lands where kimi looks for it. Long name exercises the 40-char
#    slug truncation; mixed case and "+" exercise the slugifier.
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
TRUST_HOME="${WORK}/home"
DIR_NAME="Atrium+Kimi-Trust-Verification-Folder-With-A-Long-Name"
mkdir -p "${WORK}/${DIR_NAME}"
trap 'rm -rf "$WORK"' EXIT

expected_key="$(
  ROOT_DIR="${WORK}/${DIR_NAME}" python3 - <<'PY'
import hashlib, os, re
root = os.environ["ROOT_DIR"]
slug = re.sub(r"[^a-z0-9._-]+", "-", os.path.basename(root).lower())
slug = re.sub(r"^-+|-+$", "", slug)[:40]
slug = re.sub(r"^-+|-+$", "", slug) or "workspace"
print(f"wd_{slug}_{hashlib.sha256(root.encode()).hexdigest()[:12]}")
PY
)"

out="$(cd "${WORK}/${DIR_NAME}" && KIMI_CODE_HOME="$TRUST_HOME" "$TRUST_SH" echo exec-ran)"
check "wrapper execs its command" "$out" "exec-ran"

record="${TRUST_HOME}/workspace-trust/${expected_key}"
if [[ -f "$record" ]]; then
  echo "[PASS] record written at kimi's workdir key"
else
  echo "[FAIL] record missing at ${record}"
  echo "       present: $(ls "${TRUST_HOME}/workspace-trust" 2>/dev/null || echo none)"
  FAILURES=$((FAILURES + 1))
fi

check "record root matches the launch dir" \
  "$(jq -r '.root' "$record" 2>/dev/null)" "${WORK}/${DIR_NAME}"
check "record carries a numeric trustedAt" \
  "$(jq -r '.trustedAt | type' "$record" 2>/dev/null)" "number"

# 4. Re-running must not churn the record (kimi treats presence as trust).
before="$(cat "$record")"
(cd "${WORK}/${DIR_NAME}" && KIMI_CODE_HOME="$TRUST_HOME" "$TRUST_SH" true)
check "second launch leaves the record untouched" "$(cat "$record")" "$before"

# 5. A trust-write failure must never block the launch.
chmod 500 "${TRUST_HOME}/workspace-trust"
readonly_out="$(cd "${WORK}" && KIMI_CODE_HOME="$TRUST_HOME" "$TRUST_SH" echo still-ran || true)"
chmod 700 "${TRUST_HOME}/workspace-trust"
check "unwritable trust dir still execs" "$readonly_out" "still-ran"

if [[ "$FAILURES" -gt 0 ]]; then
  echo "kimi-workspace-trust: ${FAILURES} failure(s)"
  exit 1
fi
echo "kimi-workspace-trust: all checks passed"
