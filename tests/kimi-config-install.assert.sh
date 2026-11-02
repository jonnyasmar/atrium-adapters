#!/usr/bin/env bash
# kimi's config.toml is one file every atrium instance installs into, and kimi
# itself rewrites it (dropping comments, so atrium's block markers) on login.
# Installs used to append a blank line and a fresh block each time, leaving
# 22k blank lines and three instances' worth of hooks. This pins:
#   - install is idempotent, names no instance, and is the same bytes from any
#     instance's data dir; uninstall restores the user's file exactly;
#   - the cleanup removes every atrium hook table (marked or not, in any of
#     the spellings older installs or kimi's rewrite produced) and the blank
#     lines atrium piled up, and nothing of the user's;
#   - a cleanup that drops more than atrium's own block leaves one backup, and
#     stale temp copies (they hold credentials) are swept.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/atrium-kimi-config.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

pass() { printf '[PASS] %s\n' "$1"; }
fail() {
  printf '[FAIL] %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}
expect() {
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1: expected [$2], got [$3]"; fi
}

PYTHON="$(command -v python3)"
BEGIN='# >>> atrium kimi hooks >>>'
END='# <<< atrium kimi hooks <<<'

kimi() { # <home> <subcommand> [data dir]
  env -i HOME="$1" KIMI_CODE_HOME="$1" PATH="/usr/bin:/bin" ATRIUM_DATA_DIR="${3:-$1/.atrium-dev-probe}" \
    bash "$ROOT/adapters/kimi/hooks.sh" "$2" >/dev/null
}
fresh() { # <name> <content> → home dir with config.toml
  local home="$TMP/$1"
  mkdir -p "$home"
  printf '%s' "$2" >"$home/config.toml"
  chmod 600 "$home/config.toml"
  printf '%s' "$home"
}
count_ours() { grep -c 'adapters/kimi/kimi-hook.sh' "$1/config.toml" || true; }
# Every value but atrium's hook tables, as parsed TOML.
user_data() {
  "$PYTHON" -I -c '
import json, sys, tomllib
data = tomllib.load(open(sys.argv[1], "rb"))
data["hooks"] = [h for h in data.get("hooks", []) if "kimi-hook.sh" not in h.get("command", "") or "atrium-runtime-hook" not in h.get("command", "")]
print(json.dumps(data, sort_keys=True))' "$1/config.toml"
}

USER_CONFIG='# my kimi settings
default_model = "kimi-code/k2"

[thinking]
enabled = true

[[hooks]]
event = "PreToolUse"
command = "my-own-hook.sh --mentions kimi-hook.sh"
timeout = 5

[providers."managed:kimi-code"]
type = "kimi"
prompt = """
first paragraph


second paragraph
"""
'

# --- idempotence and instance independence -----------------------------------

home="$(fresh plain "$USER_CONFIG")"
kimi "$home" install
first="$(cat "$home/config.toml"; printf x)"
touch -t 202001010000 "$home/config.toml"
kimi "$home" install
expect "a second install changes nothing" "$first" "$(cat "$home/config.toml"; printf x)"
expect "a second install leaves the file untouched" "202001010000" "$(date -r "$home/config.toml" +%Y%m%d%H%M)"
kimi "$home" install "$TMP/.atrium-dev-other-worktree"
expect "every instance writes the same bytes" "$first" "$(cat "$home/config.toml"; printf x)"
expect "the config names no instance" "0" "$(grep -c 'atrium-dev-probe\|other-worktree' "$home/config.toml" || true)"
expect "16 atrium hooks" "16" "$(count_ours "$home")"
expect "the user's hook survives" "1" "$(grep -c 'my-own-hook.sh' "$home/config.toml")"
expect "status sees the install" '{"subcommand":"status","installed":true,"activityHooks":true}' \
  "$(env -i HOME="$home" KIMI_CODE_HOME="$home" PATH=/usr/bin:/bin bash "$ROOT/adapters/kimi/hooks.sh" status)"
expect "no backup for a clean install" "no" "$([ -e "$home/config.toml.atrium-backup" ] && echo yes || echo no)"
"$PYTHON" -I -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$home/config.toml" \
  && pass "the install parses as TOML" || fail "the install parses as TOML"
kimi "$home" uninstall
[ "$(cat "$home/config.toml"; printf x)" = "${USER_CONFIG}x" ] \
  && pass "uninstall restores the user's file byte for byte" \
  || fail "uninstall restores the user's file byte for byte"

# --- what older installs and kimi's rewrite left -----------------------------

legacy_table() { # <data dir> <event>, in the escaped-string form older installs wrote
  printf '\n[[hooks]]\nevent = "%s"\ncommand = "ATRIUM_HOOK_MARKER=atrium-runtime-hook \\"%s/adapters/kimi/kimi-hook.sh\\" \\"%s\\" \\"%s\\""\ntimeout = 10\n' \
    "$2" "$1" "x" "x"
}
rewritten_table() { # kimi's own rewrite: smol-toml spacing, no markers
  printf '[[hooks]]\nevent = "%s"\ncommand = "ATRIUM_HOOK_MARKER=atrium-runtime-hook \\"%s/adapters/kimi/kimi-hook.sh\\" \\"x\\" \\"x\\""\ntimeout = 10\n\n' \
    "$2" "$1"
}
LIVE='default_model = "kimi-code/k2"

[thinking]
enabled = true

'
for event in SessionStart PreToolUse Stop; do
  LIVE+="$(rewritten_table /Users/u/.atrium-dev "$event")"$'\n\n'
  LIVE+="$(rewritten_table /Users/u/.atrium-dev-gone "$event")"$'\n\n'
done
LIVE+='[providers."managed:kimi-code"]
type = "kimi"
'
LIVE+="$(printf '\n%.0s' $(seq 1 2000))"
LIVE+="$BEGIN"
for event in SessionStart PreToolUse Stop; do LIVE+="$(legacy_table /Users/u/.atrium-dev-hq "$event")"; done
LIVE+=$'\n'"$END"$'\n'
home="$(fresh live "$LIVE")"
before="$(user_data "$home")"
kimi "$home" install
expect "the live-shaped file keeps exactly 16 atrium hooks" "16" "$(count_ours "$home")"
expect "every orphaned instance's hooks are gone" "0" "$(grep -c '\.atrium-dev' "$home/config.toml" || true)"
expect "the user's data parses the same" "$before" "$(user_data "$home")"
expect "the blank run is gone" "0" "$(awk 'prev == "" && $0 == "" { n++ } { prev = $0 } END { print n + 0 }' "$home/config.toml")"
expect "one backup before the first cleanup" "yes" "$([ -f "$home/config.toml.atrium-backup" ] && echo yes || echo no)"
expect "the backup keeps the config's mode" "600" "$(stat -c '%a' "$home/config.toml.atrium-backup" 2>/dev/null || stat -f '%Lp' "$home/config.toml.atrium-backup")"
expect "the config keeps its mode" "600" "$(stat -c '%a' "$home/config.toml" 2>/dev/null || stat -f '%Lp' "$home/config.toml")"
expect "the file is small again" "yes" "$([ "$(wc -l <"$home/config.toml")" -lt 120 ] && echo yes || echo no)"

# --- markers and strictness ----------------------------------------------------

BROKEN="$USER_CONFIG
$BEGIN
# a note the user wrote after a crash
"
home="$(fresh broken "$BROKEN")"
kimi "$home" install
expect "a BEGIN without END loses nothing of the user's" "1" "$(grep -c 'a note the user wrote' "$home/config.toml")"
expect "and still ends with one block" "1" "$(grep -c -F "$BEGIN" "$home/config.toml")"

# --- stale temps -----------------------------------------------------------------

home="$(fresh temps "$USER_CONFIG")"
printf 'old copy' >"$home/config.toml.atrium.AAAAAA"
touch -t 202001010000 "$home/config.toml.atrium.AAAAAA"
printf 'recent copy' >"$home/config.toml.atrium.BBBBBB"
kimi "$home" install
expect "a stale temp copy is swept" "no" "$([ -e "$home/config.toml.atrium.AAAAAA" ] && echo yes || echo no)"
expect "a recent one (another install mid-write) stays" "yes" "$([ -e "$home/config.toml.atrium.BBBBBB" ] && echo yes || echo no)"
expect "the install leaves no temp of its own" "1" "$(find "$home" -name 'config.toml.atrium.??????' | wc -l | tr -d ' ')"

if [ "$FAILURES" -ne 0 ]; then
  printf '%d failure(s)\n' "$FAILURES"
  exit 1
fi
