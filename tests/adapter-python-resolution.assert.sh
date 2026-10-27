#!/usr/bin/env bash
# Every extract_session.sh, and codex's hook auto-trust, must reach a usable
# Python 3 where `python3` is not one (Windows: the Microsoft Store alias stub,
# while python.org and conda installs answer to `python` or `py -3`), give the
# same output as with python3, and fail on the documented exit code with a
# reason when there is no Python at all (issue #151).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/atrium-python-resolution.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
REAL_PYTHON="$(command -v python3)"

pass() { printf '[PASS] %s\n' "$1"; }
fail() {
  printf '[FAIL] %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

# TOOLS mirrors the system bin dirs minus every Python, so the scripts keep
# their coreutils and jq but must find the interpreter themselves.
TOOLS="$TMP/tools"
mkdir -p "$TOOLS"
for dir in /usr/bin /bin; do
  for tool in "$dir"/*; do
    name="${tool##*/}"
    case "$name" in python* | py | pydoc* | 2to3* | idle*) continue ;; esac
    [ -e "$TOOLS/$name" ] || ln -s "$tool" "$TOOLS/$name"
  done
done
[ -e "$TOOLS/jq" ] || ln -s "$(command -v jq)" "$TOOLS/jq"

# `python` is a logging shim over the real interpreter; the WindowsApps-shaped
# `python3` is a stub that logs and runs nothing, like the Store alias.
PY_BIN="$TMP/py"
STUB_DIR="$TMP/AppData/Local/Microsoft/WindowsApps"
mkdir -p "$PY_BIN" "$STUB_DIR"
printf '#!/bin/sh\necho python >>"$INTERPRETER_LOG"\nexec "%s" "$@"\n' "$REAL_PYTHON" >"$PY_BIN/python"
printf '#!/bin/sh\necho stub >>"$INTERPRETER_LOG"\nexit 9009\n' >"$STUB_DIR/python3"
chmod +x "$PY_BIN/python" "$STUB_DIR/python3"

# `py` is the Windows launcher: only `py -3 …` may reach the interpreter.
PYL_BIN="$TMP/pylauncher"
mkdir -p "$PYL_BIN"
printf '#!/bin/sh\n[ "$1" = -3 ] || { echo "py without -3" >>"$INTERPRETER_LOG"; exit 2; }\nshift\necho python >>"$INTERPRETER_LOG"\nexec "%s" "$@"\n' "$REAL_PYTHON" >"$PYL_BIN/py"
chmod +x "$PYL_BIN/py"

# The baseline: a real python3 on PATH, as on macOS and Linux.
PY3_BIN="$TMP/py3"
mkdir -p "$PY3_BIN"
ln -s "$REAL_PYTHON" "$PY3_BIN/python3"

PATH_PYTHON3="$PY3_BIN:$TOOLS"
PATH_PYTHON_ONLY="$PY_BIN:$TOOLS"
PATH_WITH_STUB="$STUB_DIR:$PY_BIN:$TOOLS"
PATH_PY_LAUNCHER="$PYL_BIN:$TOOLS"
PATH_NO_PYTHON="$TOOLS"

# The goose fixture ships as SQL; build its database once.
GOOSE_FIXTURE="$TMP/goose-fixture"
mkdir -p "$GOOSE_FIXTURE"
"$REAL_PYTHON" - "$ROOT/adapters/goose/tests/extractor/fixture.sql" "$GOOSE_FIXTURE/sessions.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[2])
conn.executescript(open(sys.argv[1], encoding='utf-8').read())
conn.commit()
PY

fixture_root() {
  case "$1" in
    goose) printf '%s' "$GOOSE_FIXTURE" ;;
    *) printf '%s' "$ROOT/adapters/$1/tests/extractor" ;;
  esac
}

fixture_session() {
  case "$1" in
    goose) printf '20260908_fix' ;;
    *) tr -d '[:space:]' <"$ROOT/adapters/$1/tests/extractor/fixture-session-id.txt" ;;
  esac
}

# Runs one extractor; prints "<exit code>" and leaves stdout/stderr in files.
run_extract() {
  local adapter="$1" path_value="$2" out="$3"
  local root session code=0
  root="$(fixture_root "$adapter")"
  session="$(fixture_session "$adapter")"
  : >"$out.log"
  env -i HOME="$TMP/home" PATH="$path_value" INTERPRETER_LOG="$out.log" \
    ATRIUM_TEST_TRANSCRIPT_ROOT="$root" \
    "$BASH" "$ROOT/adapters/$adapter/extract_session.sh" \
    --session-id "$session" --cwd /work/proj --depth deep \
    >"$out.stdout" 2>"$out.stderr" || code=$?
  printf '%s' "$code"
}

mkdir -p "$TMP/home"

# Extractors with a fixture: python-only and alias-stub PATHs must reach
# `python` and print exactly what python3 prints.
for adapter in antigravity claude-code codex copilot cursor-agent goose grok omp opencode pi; do
  base="$TMP/$adapter"
  expected_code="$(run_extract "$adapter" "$PATH_PYTHON3" "$base.expected")"
  if [ "$expected_code" != 0 ] || [ ! -s "$base.expected.stdout" ]; then
    fail "$adapter extractor baseline (exit $expected_code): $(head -c 300 "$base.expected.stderr")"
    continue
  fi
  cases=("python-only:$PATH_PYTHON_ONLY" "py-launcher:$PATH_PY_LAUNCHER")
  if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    cases+=("alias-stub:$PATH_WITH_STUB")
  else
    printf '[SKIP] %s extractor alias-stub case needs bash >= 4 (Git Bash is 5)\n' "$adapter"
  fi
  for entry in "${cases[@]}"; do
    label="${entry%%:*}"
    path_value="${entry#*:}"
    code="$(run_extract "$adapter" "$path_value" "$base.$label")"
    if [ "$code" != 0 ]; then
      fail "$adapter extractor $label: exit $code: $(head -c 300 "$base.$label.stderr")"
    elif grep -q -e stub -e "py without -3" "$base.$label.log"; then
      fail "$adapter extractor $label: ran the alias stub or \`py\` without -3"
    elif ! grep -q python "$base.$label.log"; then
      fail "$adapter extractor $label: never reached \`python\`"
    elif ! cmp -s "$base.expected.stdout" "$base.$label.stdout"; then
      fail "$adapter extractor $label: output differs from python3"
    else
      pass "$adapter extractor $label matches python3 byte for byte"
    fi
  done
done

# Every extractor (fixture or not) answers "no Python" with exit 3 and a reason.
for script in "$ROOT"/adapters/*/extract_session.sh; do
  adapter="$(basename "$(dirname "$script")")"
  code=0
  env -i HOME="$TMP/home" PATH="$PATH_NO_PYTHON" ATRIUM_TEST_TRANSCRIPT_ROOT="$TMP/none" \
    "$BASH" "$script" --session-id missing --cwd /work/proj --depth deep \
    >"$TMP/$adapter.nopy.stdout" 2>"$TMP/$adapter.nopy.stderr" || code=$?
  if [ "$code" = 3 ] && grep -q "no runnable Python 3" "$TMP/$adapter.nopy.stderr"; then
    pass "$adapter extractor without Python exits 3 with a reason"
  else
    fail "$adapter extractor without Python: exit $code: $(head -c 300 "$TMP/$adapter.nopy.stderr")"
  fi
done

# hermes and muse hand their arguments straight to Python; they only have to
# reach it.
for adapter in hermes muse; do
  log="$TMP/$adapter.reach.log"
  : >"$log"
  env -i HOME="$TMP/home" PATH="$PATH_PYTHON_ONLY" INTERPRETER_LOG="$log" \
    "$BASH" "$ROOT/adapters/$adapter/extract_session.sh" \
    --session-id missing --cwd /work/proj --depth deep >/dev/null 2>&1 || true
  if grep -q python "$log"; then
    pass "$adapter extractor falls back to \`python\`"
  else
    fail "$adapter extractor never reached \`python\`"
  fi
done

# codex auto-trust: with only `python` it must still pre-trust the hooks,
# writing the same config.toml python3 writes, and uninstall must remove it.
# One HOME for every run: the trust keys embed hooks.json's absolute path.
CODEX_HOME_DIR="$TMP/codex-home"
codex_install() {
  local label="$1" path_value="$2" code=0
  rm -rf "$CODEX_HOME_DIR"
  mkdir -p "$CODEX_HOME_DIR/.codex"
  printf '# user line kept\nmodel = "gpt-x"\n' >"$CODEX_HOME_DIR/.codex/config.toml"
  : >"$TMP/codex-$label.log"
  env -i HOME="$CODEX_HOME_DIR" PATH="$path_value" INTERPRETER_LOG="$TMP/codex-$label.log" \
    ATRIUM_DATA_DIR="$TMP/data" \
    "$BASH" "$ROOT/adapters/codex/hooks.sh" install >"$TMP/codex-$label.stdout" 2>"$TMP/codex-$label.stderr" || code=$?
  cp "$CODEX_HOME_DIR/.codex/config.toml" "$TMP/codex-$label.toml"
  return "$code"
}

if codex_install python3 "$PATH_PYTHON3" && grep -q '^\[hooks\.state\.' "$TMP/codex-python3.toml"; then
  if ! codex_install python "$PATH_PYTHON_ONLY"; then
    fail "codex auto-trust with \`python\`: install failed: $(head -c 300 "$TMP/codex-python.stderr")"
  elif ! grep -q python "$TMP/codex-python.log"; then
    fail "codex auto-trust with \`python\`: never reached it"
  elif ! cmp -s "$TMP/codex-python3.toml" "$TMP/codex-python.toml"; then
    fail "codex auto-trust with \`python\`: config.toml differs from python3's"
  else
    pass "codex auto-trust with \`python\` writes python3's config.toml byte for byte"
  fi
  if env -i HOME="$CODEX_HOME_DIR" PATH="$PATH_PYTHON_ONLY" INTERPRETER_LOG="$TMP/codex-python.log" \
    ATRIUM_DATA_DIR="$TMP/data" "$BASH" "$ROOT/adapters/codex/hooks.sh" uninstall >/dev/null 2>&1 \
    && ! grep -q '^\[hooks\.state\.' "$CODEX_HOME_DIR/.codex/config.toml" \
    && grep -q '^# user line kept$' "$CODEX_HOME_DIR/.codex/config.toml"; then
    pass "codex uninstall with \`python\` removes only atrium's trust entries"
  else
    fail "codex uninstall with \`python\` left trust entries or dropped user lines"
  fi
else
  fail "codex auto-trust baseline with python3: $(head -c 300 "$TMP/codex-python3.stderr")"
fi

if codex_install none "$PATH_NO_PYTHON" \
  && grep -q "no runnable Python 3" "$TMP/codex-none.stderr" \
  && ! grep -q '^\[hooks\.state\.' "$TMP/codex-none.toml"; then
  pass "codex install without Python still succeeds and says why trust was skipped"
else
  fail "codex install without Python: $(head -c 300 "$TMP/codex-none.stderr")"
fi

if [ "$FAILURES" -ne 0 ]; then
  printf '%d failure(s)\n' "$FAILURES"
  exit 1
fi
