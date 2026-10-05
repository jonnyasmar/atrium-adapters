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
url="${*: -1}"
echo "$url" >>"${CURL_LOG:?}"
[ "${MOCK_CURL_FAIL:-0}" = "1" ] && exit 22
case "$url" in
  https://formulae.brew.sh/api/cask/*) printf '{"version":"%s"}\n' "${MOCK_BREW_VERSION:?}" ;;
  https://formulae.brew.sh/api/formula/*) printf '{"versions":{"stable":"%s"}}\n' "${MOCK_BREW_VERSION:?}" ;;
  *) printf '{"latest":"%s"}\n' "${MOCK_LATEST_VERSION:?}" ;;
esac
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

make_managed_adapter_layout() {
  local adapters_dir="$TMP/managed/adapters"
  local artifact generation_dir

  mkdir -p "$adapters_dir"
  for artifact in claude-code codex opencode shared; do
    generation_dir="$adapters_dir/.managed/$artifact/generations/test"
    mkdir -p "$generation_dir"
    cp -R "$REPO_ROOT/adapters/$artifact/." "$generation_dir/"
    ln -s ".managed/$artifact/generations/test" "$adapters_dir/$artifact"
  done

  printf '%s\n' "$adapters_dir"
}

MANAGED_ADAPTERS_DIR="$(make_managed_adapter_layout)"

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

# Lays out <brew_root>/{bin,Caskroom|Cellar} the way Homebrew links a binary,
# with an install receipt naming the tap the package came from.
make_brew_install() {
  local brew_root="$1" binary="$2" package_dir="$3" tap="$4"
  local receipt

  make_stubs "$brew_root/bin"
  make_tool "$brew_root/$package_dir/2.1.231/$binary"
  ln -s "../$package_dir/2.1.231/$binary" "$brew_root/bin/$binary"

  case "$package_dir" in
    Caskroom/*) receipt="$brew_root/$package_dir/.metadata/INSTALL_RECEIPT.json" ;;
    Cellar/*) receipt="$brew_root/$package_dir/2.1.231/INSTALL_RECEIPT.json" ;;
  esac
  mkdir -p "$(dirname "$receipt")"
  jq -n --arg tap "$tap" '{source: {tap: $tap}}' >"$receipt"
}

run_check() {
  local script="$1" bin_dir="$2" curl_log="$3" brew_version="$4"
  shift 4
  env PATH="$bin_dir:$SYSTEM_PATH" \
    CURL_LOG="$curl_log" \
    MOCK_INSTALLED_VERSION=2.1.231 \
    MOCK_LATEST_VERSION=2.1.240 \
    MOCK_BREW_VERSION="$brew_version" \
    "$@" \
    "$script"
}

check_adapter() {
  local adapter="$1" binary="$2" package_dir="$3"
  local script="$MANAGED_ADAPTERS_DIR/$adapter/check_update.sh"
  local case_dir="$TMP/${package_dir//\//-}"
  local api_url official_tap brew_root out

  case "$package_dir" in
    Caskroom/*)
      api_url="https://formulae.brew.sh/api/cask/${package_dir#Caskroom/}.json"
      official_tap="homebrew/cask"
      ;;
    Cellar/*)
      api_url="https://formulae.brew.sh/api/formula/${package_dir#Cellar/}.json"
      official_tap="homebrew/core"
      ;;
  esac

  # Official tap with a newer published version: compare against Homebrew
  # (2.1.235), never npm (2.1.240) — brew can't install what it hasn't published.
  brew_root="$case_dir-brew-newer"
  make_brew_install "$brew_root" "$binary" "$package_dir" "$official_tap"
  out="$(run_check "$script" "$brew_root/bin" "$brew_root/curl.log" 2.1.235)"
  assert_result "$adapter Homebrew install behind its tap" "$out" "2.1.235" "true"
  [ "$(cat "$brew_root/curl.log")" = "$api_url" ] \
    || fail "$adapter did not query exactly $api_url" "$(cat "$brew_root/curl.log")"

  brew_root="$case_dir-brew-current"
  make_brew_install "$brew_root" "$binary" "$package_dir" "$official_tap"
  out="$(run_check "$script" "$brew_root/bin" "$brew_root/curl.log" 2.1.231)"
  assert_result "$adapter Homebrew install matching its tap" "$out" "2.1.231" "false"

  # Third-party taps aren't on formulae.brew.sh; a same-named official package
  # could report an unrelated version, so stay quiet and off the network.
  brew_root="$case_dir-brew-third-party"
  make_brew_install "$brew_root" "$binary" "$package_dir" "someone/tap"
  out="$(run_check "$script" "$brew_root/bin" "$brew_root/curl.log" 2.1.235)"
  assert_result "$adapter third-party tap install" "$out" "2.1.231" "false"
  [ ! -e "$brew_root/curl.log" ] || fail "$adapter queried the network for a third-party tap"

  brew_root="$case_dir-brew-offline"
  make_brew_install "$brew_root" "$binary" "$package_dir" "$official_tap"
  out="$(run_check "$script" "$brew_root/bin" "$brew_root/curl.log" 2.1.235 MOCK_CURL_FAIL=1)"
  [ "$(printf '%s' "$out" | jq -r '.updateAvailable')" = "false" ] \
    && [ -n "$(printf '%s' "$out" | jq -r '.error // empty')" ] \
    || fail "$adapter did not report a failed Homebrew lookup as an error" "$out"

  local npm_root="$case_dir-npm"
  make_stubs "$npm_root/bin"
  make_tool "$npm_root/lib/node_modules/$adapter/cli.js"
  ln -s "../lib/node_modules/$adapter/cli.js" "$npm_root/bin/$binary"
  out="$(run_check "$script" "$npm_root/bin" "$npm_root/curl.log" 2.1.235)"
  assert_result "$adapter npm install" "$out" "2.1.240" "true"
  [ "$(wc -l <"$npm_root/curl.log" | tr -d ' ')" = "1" ] \
    || fail "$adapter npm install did not query the registry exactly once"
  grep -q '^https://registry.npmjs.org/' "$npm_root/curl.log" \
    || fail "$adapter npm install did not query npm" "$(cat "$npm_root/curl.log")"

  echo "[PASS] $adapter checks Homebrew installs against Homebrew and npm installs against npm"
}

check_adapter claude-code claude Caskroom/claude-code
check_adapter claude-code claude Caskroom/claude-code@latest
check_adapter codex codex Caskroom/codex
check_adapter opencode opencode Cellar/opencode

# `claude update` only prints brew instructions for a Homebrew install, so the
# manifest's updateCommand must run brew itself. Execute the real argv.
check_claude_update_command() {
  local name="$1" expected="$2" root="$TMP/claude-update-$1"
  local -a argv=()
  local arg log

  while IFS= read -r arg; do argv+=("$arg"); done \
    < <(jq -r '.updateCommand[]' "$REPO_ROOT/adapters/claude-code/adapter.json")

  mkdir -p "$root/bin"
  for stub in brew claude; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >>"$CMD_LOG"\n' "$stub" >"$root/bin/$stub.stub"
    chmod +x "$root/bin/$stub.stub"
  done
  mv "$root/bin/brew.stub" "$root/bin/brew"

  case "$name" in
    cask)
      mkdir -p "$root/Caskroom/claude-code@latest/2.1.231"
      mv "$root/bin/claude.stub" "$root/Caskroom/claude-code@latest/2.1.231/claude"
      ln -s "$root/Caskroom/claude-code@latest/2.1.231/claude" "$root/bin/claude"
      ;;
    formula)
      mkdir -p "$root/Cellar/claude-code/2.1.231/bin"
      mv "$root/bin/claude.stub" "$root/Cellar/claude-code/2.1.231/bin/claude"
      ln -s "../Cellar/claude-code/2.1.231/bin/claude" "$root/bin/claude"
      ;;
    native)
      mv "$root/bin/claude.stub" "$root/bin/claude"
      ;;
  esac

  log="$root/commands.log"
  (cd "$TMP" && PATH="$root/bin:$SYSTEM_PATH" CMD_LOG="$log" "${argv[@]}") \
    || fail "claude-code updateCommand exited non-zero for a $name install"
  [ "$(cat "$log")" = "$expected" ] \
    || fail "claude-code updateCommand ran the wrong command for a $name install" "$(cat "$log")"
}

check_claude_update_command cask "brew upgrade --cask claude-code@latest"
check_claude_update_command formula "brew upgrade claude-code"
check_claude_update_command native "claude update"
echo "[PASS] claude-code updateCommand routes Homebrew installs to brew"

echo "[PASS] Homebrew-managed update checks complete"
