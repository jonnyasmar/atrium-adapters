#!/usr/bin/env bash
# Executes each npm-distributed adapter's updateCommand router and check_update
# against stub mise/npm/brew/harness binaries, so a mise- or foreign-prefix
# install is updated where it lives instead of a second copy landing elsewhere
# (jonnyasmar/atrium-issues#131).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# No mise, npm or brew beyond the stubs each case puts first on PATH.
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
JQ="$(command -v jq)"

fail() {
  echo "[FAIL] $1" >&2
  [ -z "${2:-}" ] || echo "$2" >&2
  exit 1
}

write_stub() {
  mkdir -p "$(dirname "$1")"
  cat >"$1"
  chmod +x "$1"
}

# A harness binary: answers --version with a fixed version, logs anything else.
make_tool() {
  write_stub "$1" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then echo "$2"; exit 0; fi
echo "\${0##*/} \$*" >>"\$CMD_LOG"
EOF
}

make_mise() {
  write_stub "$1" <<'EOF'
#!/usr/bin/env bash
# Invoked through a shim symlink: run the tool mise resolves, as real shims do.
[ "${0##*/}" = mise ] || exec "${MOCK_MISE_WHICH:?}" "$@"
case "$1 ${2:-}" in
  "which --plugin")
    echo "mise which --plugin $3 (cwd=$PWD, MISE_DATA_DIR=${MISE_DATA_DIR:-})" >>"$QUERY_LOG"
    [ -n "${MOCK_MISE_PLUGIN:-}" ] || exit 1
    echo "$MOCK_MISE_PLUGIN"
    ;;
  "which "*)
    echo "mise which $2 (cwd=$PWD, MISE_DATA_DIR=${MISE_DATA_DIR:-})" >>"$QUERY_LOG"
    [ -n "${MOCK_MISE_WHICH:-}" ] || exit 1
    echo "$MOCK_MISE_WHICH"
    ;;
  "latest "*)
    echo "mise latest $2 (cwd=$PWD, MISE_DATA_DIR=${MISE_DATA_DIR:-})" >>"$QUERY_LOG"
    echo "${MOCK_MISE_LATEST:?}"
    ;;
  *)
    echo "mise $* (cwd=$PWD, MISE_YES=${MISE_YES:-}, MISE_DATA_DIR=${MISE_DATA_DIR:-})" >>"$CMD_LOG"
    [ -z "${MOCK_MISE_FAIL:-}" ] || { echo "mise ERROR Run with --verbose for more information" >&2; exit 1; }
    ;;
esac
EOF
}

# make_npm <path> <label>: `prefix -g` reports MOCK_NPM_PREFIX; installs log
# (and fail when MOCK_NPM_FAIL is set).
make_npm() {
  write_stub "$1" <<EOF
#!/usr/bin/env bash
if [ "\$1 \${2:-}" = "prefix -g" ]; then
  [ -n "\${MOCK_NPM_PREFIX:-}" ] || exit 1
  echo "\$MOCK_NPM_PREFIX"
  exit 0
fi
echo "$2 \$*" >>"\$CMD_LOG"
[ -z "\${MOCK_NPM_FAIL:-}" ] || { echo "npm error A complete log of this run can be found in: /tmp/x.log" >&2; exit 1; }
EOF
}

make_brew() {
  write_stub "$1" <<'EOF'
#!/usr/bin/env bash
echo "brew $*" >>"$CMD_LOG"
EOF
}

make_curl() {
  write_stub "$1" <<'EOF'
#!/usr/bin/env bash
echo "${*: -1}" >>"$CURL_LOG"
printf '{"latest":"%s"}\n' "${MOCK_NPM_LATEST:?}"
EOF
}

# npm_tree <prefix> <binary> <package> <version>: the layout `npm install -g`
# (and mise's npm backend before aube) leaves under a prefix.
npm_tree() {
  local prefix="$1" binary="$2" package="$3" version="$4"
  make_tool "$prefix/lib/node_modules/$package/bin/cli.js" "$version"
  mkdir -p "$prefix/bin"
  ln -s "../lib/node_modules/$package/bin/cli.js" "$prefix/bin/$binary"
}

ADAPTER="" BINARY="" PACKAGE="" NAME="" FALLBACK="" NPM_PRE="" NPM_POST="" SEGMENT=""

set_adapter() {
  local key=""
  ADAPTER="$1" BINARY="$2" PACKAGE="$3" NAME="$4" FALLBACK="$5" NPM_PRE="$6" NPM_POST="$7"
  key="${PACKAGE#@}"
  SEGMENT="npm-${key//\//-}"
}

# expected_bump <mise data dir>
expected_bump() {
  printf 'mise upgrade --bump npm:%s (cwd=%s/home, MISE_YES=1, MISE_DATA_DIR=%s)' "$PACKAGE" "$CASE" "$1"
}

expected_npm_install() {
  printf '%s install -g %s--prefix %s %s' "$1" "${NPM_PRE:+$NPM_PRE }" "$2" "$NPM_POST"
}

CASE="" OUT="" ERR="" STATUS=0

new_case() {
  CASE="$TMP/$ADAPTER-$1"
  mkdir -p "$CASE/home" "$CASE/stubs"
  : >"$CASE/commands.log"
  : >"$CASE/queries.log"
  : >"$CASE/curl.log"
}

# run_router <path> [VAR=value...]: the manifest's real updateCommand argv,
# from a scrubbed environment.
run_router() {
  local path="$1"
  local -a argv=()
  local arg
  shift
  while IFS= read -r arg; do argv+=("$arg"); done \
    < <("$JQ" -r '.updateCommand[]' "$REPO_ROOT/adapters/$ADAPTER/adapter.json")
  STATUS=0
  (cd "$TMP" && env -i HOME="$CASE/home" PATH="$path" CMD_LOG="$CASE/commands.log" \
    QUERY_LOG="$CASE/queries.log" "$@" "${argv[@]}" </dev/null >"$CASE/stdout" 2>"$CASE/stderr") \
    || STATUS=$?
  ERR="$(cat "$CASE/stderr")"
}

run_check() {
  local path="$1"
  shift
  ln -sf "$JQ" "$CASE/stubs/jq"
  make_curl "$CASE/stubs/curl"
  OUT="$(cd "$TMP" && env -i HOME="$CASE/home" PATH="$path" CMD_LOG="$CASE/commands.log" \
    QUERY_LOG="$CASE/queries.log" CURL_LOG="$CASE/curl.log" MOCK_NPM_LATEST=0.161.0 "$@" \
    bash "$REPO_ROOT/adapters/$ADAPTER/check_update.sh")"
}

assert_ran() {
  local label="$1" expected="$2"
  [ "$STATUS" = "0" ] || fail "$ADAPTER $label: router exited $STATUS" "$ERR"
  [ "$(cat "$CASE/commands.log")" = "$expected" ] \
    || fail "$ADAPTER $label: expected exactly: $expected" "$(cat "$CASE/commands.log")"
}

# The core contract: a failed or refused update's last non-empty stderr line
# is the reason shown to the user.
assert_reason() {
  local label="$1" status="$2" expected="$3" last_line=""
  [ "$STATUS" = "$status" ] || fail "$ADAPTER $label: expected exit $status, got $STATUS" "$ERR"
  last_line="$(printf '%s\n' "$ERR" | sed '/^[[:space:]]*$/d' | tail -n 1)"
  [ "$last_line" = "$expected" ] || fail "$ADAPTER $label: wrong reason" "$ERR"
}

assert_refused() {
  assert_reason "$1" 3 "$2"
  [ ! -s "$CASE/commands.log" ] || fail "$ADAPTER $1: ran a command" "$(cat "$CASE/commands.log")"
}

assert_check() {
  local label="$1" installed="$2" latest="$3" available="$4"
  [ "$(printf '%s' "$OUT" | "$JQ" -r '.installedVersion')" = "$installed" ] \
    && [ "$(printf '%s' "$OUT" | "$JQ" -r '.latestVersion')" = "$latest" ] \
    && [ "$(printf '%s' "$OUT" | "$JQ" -r '.updateAvailable')" = "$available" ] \
    || fail "$ADAPTER check_update $label: expected $installed -> $latest ($available)" "$OUT"
}

check_router() {
  local data prefix

  # The #131 install: `mise use -g npm:<pkg>@<old>` put the npm shim of a
  # versioned mise install on PATH.
  new_case mise-install
  data="$CASE/share/mise"
  npm_tree "$data/installs/$SEGMENT/0.144.4" "$BINARY" "$PACKAGE" 0.144.4
  make_mise "$CASE/stubs/mise"
  make_npm "$CASE/stubs/npm" npm
  run_router "$data/installs/$SEGMENT/0.144.4/bin:$CASE/stubs:$BASE_PATH" MOCK_MISE_PLUGIN="npm:$PACKAGE"
  assert_ran "mise install" "$(expected_bump "$data")"

  # mise's aube-backed npm installs expose a sh shim under node_modules/.bin.
  new_case mise-aube
  data="$CASE/share/mise"
  make_tool "$data/installs/$SEGMENT/0.144.4/node_modules/.bin/$BINARY" 0.144.4
  make_mise "$CASE/stubs/mise"
  make_npm "$CASE/stubs/npm" npm
  run_router "$data/installs/$SEGMENT/0.144.4/node_modules/.bin:$CASE/stubs:$BASE_PATH" MOCK_MISE_PLUGIN="npm:$PACKAGE"
  assert_ran "mise aube install" "$(expected_bump "$data")"

  new_case mise-shim
  data="$CASE/share/mise"
  make_mise "$CASE/stubs/mise"
  make_npm "$CASE/stubs/npm" npm
  mkdir -p "$data/shims"
  ln -s "$CASE/stubs/mise" "$data/shims/$BINARY"
  run_router "$data/shims:$CASE/stubs:$BASE_PATH" MOCK_MISE_PLUGIN="npm:$PACKAGE"
  assert_ran "mise shim" "$(expected_bump "$data")"

  # `eval "$(~/.local/bin/mise activate --shims)"` leaves mise itself off PATH;
  # the shim's own target is the mise to run.
  new_case mise-shim-offpath
  data="$CASE/share/mise"
  make_mise "$CASE/tools/mise"
  mkdir -p "$data/shims"
  ln -s "$CASE/tools/mise" "$data/shims/$BINARY"
  run_router "$data/shims:$BASE_PATH" MOCK_MISE_PLUGIN="npm:$PACKAGE"
  assert_ran "mise shim without mise on PATH" "$(expected_bump "$data")"

  # A custom MISE_DATA_DIR is recognised by the backend record mise writes,
  # not by the env var: check_update only gets the boot PATH, and both must
  # agree. mise then runs against the data dir the path implies.
  new_case mise-data-dir
  data="$CASE/tool-data"
  npm_tree "$data/installs/$SEGMENT/0.144.4" "$BINARY" "$PACKAGE" 0.144.4
  printf 'short = "npm:%s"\n' "$PACKAGE" >"$data/installs/$SEGMENT/.mise.backend.toml"
  make_mise "$CASE/stubs/mise"
  run_router "$data/installs/$SEGMENT/0.144.4/bin:$CASE/stubs:$BASE_PATH" MOCK_MISE_PLUGIN="npm:$PACKAGE"
  assert_ran "custom data dir install without MISE_DATA_DIR" "$(expected_bump "$data")"

  new_case mise-data-dir-env
  data="$CASE/tool-data"
  npm_tree "$data/installs/$SEGMENT/0.144.4" "$BINARY" "$PACKAGE" 0.144.4
  printf 'short = "npm:%s"\n' "$PACKAGE" >"$data/installs/$SEGMENT/.mise.backend.toml"
  make_mise "$CASE/stubs/mise"
  run_router "$data/installs/$SEGMENT/0.144.4/bin:$CASE/stubs:$BASE_PATH" \
    MISE_DATA_DIR="$data" MOCK_MISE_PLUGIN="npm:$PACKAGE"
  assert_ran "custom data dir install with MISE_DATA_DIR" "$(expected_bump "$data")"

  new_case mise-data-dir-shim
  data="$CASE/tool-data"
  make_mise "$CASE/stubs/mise"
  mkdir -p "$data/shims"
  ln -s "$CASE/stubs/mise" "$data/shims/$BINARY"
  run_router "$data/shims:$CASE/stubs:$BASE_PATH" MOCK_MISE_PLUGIN="npm:$PACKAGE"
  assert_ran "custom data dir shim without MISE_DATA_DIR" "$(expected_bump "$data")"

  new_case mise-upgrade-fails
  data="$CASE/share/mise"
  npm_tree "$data/installs/$SEGMENT/0.144.4" "$BINARY" "$PACKAGE" 0.144.4
  make_mise "$CASE/stubs/mise"
  run_router "$data/installs/$SEGMENT/0.144.4/bin:$CASE/stubs:$BASE_PATH" \
    MOCK_MISE_PLUGIN="npm:$PACKAGE" MOCK_MISE_FAIL=1
  assert_reason "mise upgrade failure" 1 \
    "Updating $NAME with mise failed. Run: mise upgrade --bump npm:$PACKAGE"

  new_case mise-missing
  data="$CASE/share/mise"
  npm_tree "$data/installs/$SEGMENT/0.144.4" "$BINARY" "$PACKAGE" 0.144.4
  make_npm "$CASE/stubs/npm" npm
  run_router "$data/installs/$SEGMENT/0.144.4/bin:$CASE/stubs:$BASE_PATH"
  assert_refused "mise not on PATH" \
    "$NAME is installed by mise ($data/installs/$SEGMENT), but mise is not on PATH. Run: mise upgrade --bump npm:$PACKAGE"

  new_case mise-inactive
  data="$CASE/share/mise"
  npm_tree "$data/installs/$SEGMENT/0.144.4" "$BINARY" "$PACKAGE" 0.144.4
  make_mise "$CASE/stubs/mise"
  run_router "$data/installs/$SEGMENT/0.144.4/bin:$CASE/stubs:$BASE_PATH"
  assert_refused "mise install no home config selects" \
    "$NAME is installed by mise ($data/installs/$SEGMENT), but no mise config in your home directory selects it. Run: mise use -g npm:$PACKAGE@latest"

  # `npm install -g` under a mise-managed node belongs to npm, not a mise pin.
  new_case mise-node-match
  data="$CASE/share/mise"
  prefix="$data/installs/node/22.13.1"
  npm_tree "$prefix" "$BINARY" "$PACKAGE" 0.144.4
  make_mise "$CASE/stubs/mise"
  make_npm "$CASE/stubs/npm" npm
  run_router "$prefix/bin:$CASE/stubs:$BASE_PATH" MOCK_MISE_PLUGIN=node MOCK_NPM_PREFIX="$prefix"
  assert_ran "npm global under mise node" "$FALLBACK"

  new_case mise-node-mismatch
  data="$CASE/share/mise"
  prefix="$data/installs/node/22.13.1"
  npm_tree "$prefix" "$BINARY" "$PACKAGE" 0.144.4
  make_npm "$prefix/bin/npm" prefix-npm
  make_mise "$CASE/stubs/mise"
  make_npm "$CASE/stubs/npm" npm
  run_router "$CASE/stubs:$prefix/bin:$BASE_PATH" MOCK_MISE_PLUGIN=node MOCK_NPM_PREFIX="$CASE/global"
  assert_ran "npm global under mise node, foreign npm first" "$(expected_npm_install prefix-npm "$prefix")"

  new_case mise-shim-node
  data="$CASE/share/mise"
  prefix="$data/installs/node/22.13.1"
  npm_tree "$prefix" "$BINARY" "$PACKAGE" 0.144.4
  make_mise "$CASE/stubs/mise"
  make_npm "$CASE/stubs/npm" npm
  mkdir -p "$data/shims"
  ln -s "$CASE/stubs/mise" "$data/shims/$BINARY"
  run_router "$data/shims:$CASE/stubs:$BASE_PATH" MOCK_MISE_PLUGIN=node \
    MOCK_MISE_WHICH="$prefix/bin/$BINARY" MOCK_NPM_PREFIX="$prefix"
  assert_ran "mise shim for an npm global under mise node" "$FALLBACK"

  new_case npm-foreign-prefix
  npm_tree "$CASE/prefix" "$BINARY" "$PACKAGE" 0.144.4
  make_npm "$CASE/stubs/npm" npm
  run_router "$CASE/prefix/bin:$CASE/stubs:$BASE_PATH" MOCK_NPM_PREFIX="$CASE/global"
  assert_ran "npm tree outside npm's global prefix" "$(expected_npm_install npm "$CASE/prefix")"

  new_case npm-install-fails
  npm_tree "$CASE/prefix" "$BINARY" "$PACKAGE" 0.144.4
  make_npm "$CASE/stubs/npm" npm
  run_router "$CASE/prefix/bin:$CASE/stubs:$BASE_PATH" MOCK_NPM_PREFIX="$CASE/global" MOCK_NPM_FAIL=1
  assert_reason "npm install failure" 1 \
    "Updating $NAME with npm failed. Run: $(expected_npm_install npm "$CASE/prefix")"

  new_case npm-global-prefix
  npm_tree "$CASE/prefix" "$BINARY" "$PACKAGE" 0.144.4
  make_npm "$CASE/stubs/npm" npm
  run_router "$CASE/prefix/bin:$CASE/stubs:$BASE_PATH" MOCK_NPM_PREFIX="$CASE/prefix/"
  assert_ran "npm tree in npm's global prefix" "$FALLBACK"

  new_case npm-missing
  npm_tree "$CASE/prefix" "$BINARY" "$PACKAGE" 0.144.4
  run_router "$CASE/prefix/bin:$BASE_PATH"
  assert_refused "npm tree without npm" \
    "$NAME was installed with npm into $CASE/prefix, but npm is not on PATH."

  new_case brew-cask
  make_tool "$CASE/brew/Caskroom/$ADAPTER/1.0.0/$BINARY" 1.0.0
  mkdir -p "$CASE/brew/bin"
  ln -s "../Caskroom/$ADAPTER/1.0.0/$BINARY" "$CASE/brew/bin/$BINARY"
  make_brew "$CASE/stubs/brew"
  make_npm "$CASE/stubs/npm" npm
  run_router "$CASE/brew/bin:$CASE/stubs:$BASE_PATH"
  if [ "$ADAPTER" = claude-code ]; then
    assert_ran "Homebrew cask" "brew upgrade --cask $ADAPTER"
  else
    assert_ran "Homebrew cask" "$FALLBACK"
  fi

  new_case standalone
  make_tool "$CASE/bin/$BINARY" 1.0.0
  make_npm "$CASE/stubs/npm" npm
  run_router "$CASE/bin:$CASE/stubs:$BASE_PATH"
  assert_ran "standalone install" "$FALLBACK"

  echo "[PASS] $ADAPTER updateCommand routes mise and foreign-prefix npm installs"
}

check_update_reads_mise() {
  local data

  # A PATH captured before the upgrade still names 0.144.4, which mise keeps
  # until it prunes it; mise says what is current.
  new_case check-stale-path
  data="$CASE/share/mise"
  npm_tree "$data/installs/$SEGMENT/0.144.4" "$BINARY" "$PACKAGE" 0.144.4
  npm_tree "$data/installs/$SEGMENT/0.161.0" "$BINARY" "$PACKAGE" 0.161.0
  make_mise "$CASE/stubs/mise"
  run_check "$data/installs/$SEGMENT/0.144.4/bin:$CASE/stubs:$BASE_PATH" \
    MOCK_MISE_PLUGIN="npm:$PACKAGE" MOCK_MISE_WHICH="$data/installs/$SEGMENT/0.161.0/bin/$BINARY" \
    MOCK_MISE_LATEST=0.161.0
  assert_check "stale PATH after a mise bump" 0.161.0 0.161.0 false
  [ ! -s "$CASE/curl.log" ] || fail "$ADAPTER check_update queried npm for a mise install"
  grep -qx "mise latest npm:$PACKAGE (cwd=$CASE/home, MISE_DATA_DIR=$data)" "$CASE/queries.log" \
    || fail "$ADAPTER check_update did not ask mise for the latest version from \$HOME" "$(cat "$CASE/queries.log")"

  # mise holds back releases younger than minimum_release_age; the check must
  # not offer a version the mise bump cannot reach.
  new_case check-release-age
  data="$CASE/share/mise"
  npm_tree "$data/installs/$SEGMENT/0.144.4" "$BINARY" "$PACKAGE" 0.144.4
  make_mise "$CASE/stubs/mise"
  run_check "$data/installs/$SEGMENT/0.144.4/bin:$CASE/stubs:$BASE_PATH" \
    MOCK_MISE_PLUGIN="npm:$PACKAGE" MOCK_MISE_WHICH="$data/installs/$SEGMENT/0.144.4/bin/$BINARY" \
    MOCK_MISE_LATEST=0.160.1
  assert_check "mise latest trails npm" 0.144.4 0.160.1 true

  new_case check-data-dir
  data="$CASE/tool-data"
  npm_tree "$data/installs/$SEGMENT/0.144.4" "$BINARY" "$PACKAGE" 0.144.4
  npm_tree "$data/installs/$SEGMENT/0.161.0" "$BINARY" "$PACKAGE" 0.161.0
  printf 'short = "npm:%s"\n' "$PACKAGE" >"$data/installs/$SEGMENT/.mise.backend.toml"
  make_mise "$CASE/stubs/mise"
  run_check "$data/installs/$SEGMENT/0.144.4/bin:$CASE/stubs:$BASE_PATH" \
    MOCK_MISE_PLUGIN="npm:$PACKAGE" MOCK_MISE_WHICH="$data/installs/$SEGMENT/0.161.0/bin/$BINARY" \
    MOCK_MISE_LATEST=0.161.0
  assert_check "custom data dir without MISE_DATA_DIR" 0.161.0 0.161.0 false
  grep -qx "mise which $BINARY (cwd=$CASE/home, MISE_DATA_DIR=$data)" "$CASE/queries.log" \
    || fail "$ADAPTER check_update did not point mise at the binary's data dir" "$(cat "$CASE/queries.log")"

  new_case check-no-mise
  data="$CASE/share/mise"
  npm_tree "$data/installs/$SEGMENT/0.144.4" "$BINARY" "$PACKAGE" 0.144.4
  run_check "$data/installs/$SEGMENT/0.144.4/bin:$CASE/stubs:$BASE_PATH"
  assert_check "mise install without mise on PATH" 0.144.4 0.161.0 true
  [ "$(wc -l <"$CASE/curl.log" | tr -d ' ')" = "1" ] \
    || fail "$ADAPTER check_update did not fall back to npm exactly once" "$(cat "$CASE/curl.log")"

  new_case check-mise-node
  data="$CASE/share/mise"
  npm_tree "$data/installs/node/22.13.1" "$BINARY" "$PACKAGE" 0.144.4
  make_mise "$CASE/stubs/mise"
  run_check "$data/installs/node/22.13.1/bin:$CASE/stubs:$BASE_PATH" MOCK_MISE_PLUGIN=node
  assert_check "npm global under mise node" 0.144.4 0.161.0 true
  [ ! -s "$CASE/queries.log" ] || fail "$ADAPTER check_update consulted mise for an npm global" "$(cat "$CASE/queries.log")"

  echo "[PASS] $ADAPTER check_update reads mise installs through mise"
}

for spec in \
  "codex|codex|@openai/codex|Codex|codex update||@openai/codex" \
  "claude-code|claude|@anthropic-ai/claude-code|Claude Code|claude update|--allow-scripts=@anthropic-ai/claude-code|@anthropic-ai/claude-code" \
  "opencode|opencode|opencode-ai|OpenCode|opencode upgrade|--allow-scripts=opencode-ai|opencode-ai" \
  "pi|pi|@earendil-works/pi-coding-agent|Pi|pi update|--ignore-scripts|@earendil-works/pi-coding-agent" \
  "omp|omp|@oh-my-pi/pi-coding-agent|Oh My Pi|omp update|--allow-scripts=bun|bun @oh-my-pi/pi-coding-agent"; do
  IFS='|' read -r a b p n f pre post <<<"$spec"
  set_adapter "$a" "$b" "$p" "$n" "$f" "$pre" "$post"
  check_router
  check_update_reads_mise
done

# mise records each install's backend in .mise.backend.toml; the hint names
# that tool rather than guessing from the directory.
set_adapter codex codex @openai/codex Codex "codex update" "" "@openai/codex"
new_case mise-backend-metadata
make_tool "$CASE/share/mise/installs/aqua-openai-codex/0.144.4/bin/codex" 0.144.4
printf 'short = "aqua:openai/codex"\nfull = "aqua:openai/codex"\n' \
  >"$CASE/share/mise/installs/aqua-openai-codex/.mise.backend.toml"
run_router "$CASE/share/mise/installs/aqua-openai-codex/0.144.4/bin:$BASE_PATH"
assert_refused "non-npm mise backend without mise" \
  "Codex is installed by mise ($CASE/share/mise/installs/aqua-openai-codex), but mise is not on PATH. Run: mise upgrade --bump aqua:openai/codex"
echo "[PASS] codex updateCommand names the recorded mise backend"

echo "[PASS] mise-managed update routing complete"
