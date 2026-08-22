#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SYSTEM_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

fail() {
  echo "[FAIL] $1" >&2
  [ -z "${2:-}" ] || echo "$2" >&2
  exit 1
}

make_stubs() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
echo called >>"${CURL_LOG:?}"
printf '{"latest":"%s"}\n' "${MOCK_LATEST_VERSION:?}"
EOF
  chmod +x "$bin_dir/curl"
}

make_tool() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] || exit 1
printf '%s\n' "${MOCK_INSTALLED_VERSION:?}"
EOF
  chmod +x "$path"
}

assert_result() {
  local name="$1" output="$2" expected_latest="$3" expected_available="$4"
  printf '%s' "$output" | jq empty >/dev/null 2>&1 || fail "$name returned invalid JSON" "$output"
  [ "$(printf '%s' "$output" | jq -r '.installedVersion')" = "2.1.231" ] \
    || fail "$name reported the wrong installed version" "$output"
  [ "$(printf '%s' "$output" | jq -r '.latestVersion')" = "$expected_latest" ] \
    || fail "$name reported the wrong latest version" "$output"
  [ "$(printf '%s' "$output" | jq -r '.updateAvailable')" = "$expected_available" ] \
    || fail "$name reported the wrong availability" "$output"
}

check_adapter() {
  local adapter="$1" binary="$2" cellar_dir="$3"
  local script="$REPO_ROOT/adapters/$adapter/check_update.sh"
  local brew_root="$TMP/$adapter-homebrew"
  local brew_bin="$brew_root/bin"
  local brew_tool="$brew_root/$cellar_dir/2.1.231/$binary"
  local brew_curl_log="$brew_root/curl.log"

  make_stubs "$brew_bin"
  make_tool "$brew_tool"
  ln -s "../$cellar_dir/2.1.231/$binary" "$brew_bin/$binary"

  local brew_out
  brew_out="$(
    PATH="$brew_bin:$SYSTEM_PATH" \
      CURL_LOG="$brew_curl_log" \
      MOCK_INSTALLED_VERSION=2.1.231 \
      MOCK_LATEST_VERSION=2.1.240 \
      "$script"
  )"
  assert_result "$adapter Homebrew install" "$brew_out" "2.1.231" "false"
  [ ! -e "$brew_curl_log" ] \
    || fail "$adapter queried npm despite being package-manager-controlled"

  local npm_root="$TMP/$adapter-npm"
  local npm_bin="$npm_root/bin"
  local npm_tool="$npm_root/lib/node_modules/$adapter/cli.js"
  local npm_curl_log="$npm_root/curl.log"

  make_stubs "$npm_bin"
  make_tool "$npm_tool"
  ln -s "../lib/node_modules/$adapter/cli.js" "$npm_bin/$binary"

  local npm_out
  npm_out="$(
    PATH="$npm_bin:$SYSTEM_PATH" \
      CURL_LOG="$npm_curl_log" \
      MOCK_INSTALLED_VERSION=2.1.231 \
      MOCK_LATEST_VERSION=2.1.240 \
      "$script"
  )"
  assert_result "$adapter npm install" "$npm_out" "2.1.240" "true"
  [ "$(wc -l <"$npm_curl_log" | tr -d ' ')" = "1" ] \
    || fail "$adapter npm install did not query the registry exactly once"

  echo "[PASS] $adapter keeps Homebrew on its package-manager channel and npm on npm"
}

check_adapter claude-code claude Caskroom/claude-code
check_adapter codex codex Caskroom/codex
check_adapter opencode opencode Cellar/opencode

echo "[PASS] Homebrew-managed update checks complete"
