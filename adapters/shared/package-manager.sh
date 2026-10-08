#!/usr/bin/env bash

atrium_binary_is_homebrew_managed() {
  local binary_path="${1:-}"
  local link_target=""

  case "$binary_path" in
    */Caskroom/* | */Cellar/*) return 0 ;;
  esac

  if [[ -L "$binary_path" ]]; then
    link_target="$(readlink "$binary_path" 2>/dev/null || true)"
    case "$link_target" in
      */Caskroom/* | */Cellar/*) return 0 ;;
    esac
  fi

  return 1
}

# Prints the formulae.brew.sh API path ("cask/<token>" or "formula/<name>") of
# the package that owns a Homebrew-linked binary. Fails for third-party taps:
# the API only publishes homebrew/cask and homebrew/core, so a same-named
# official package could report an unrelated version.
atrium_official_homebrew_package() {
  local binary_path="${1:-}"
  local target="$binary_path" rest="" name="" receipt="" kind="" official_tap=""

  if [[ -L "$binary_path" ]]; then
    target="$(readlink "$binary_path" 2>/dev/null || true)"
    [[ "$target" == /* ]] || target="$(dirname "$binary_path")/$target"
  fi

  case "$target" in
    */Caskroom/*)
      rest="${target#*/Caskroom/}"
      name="${rest%%/*}"
      receipt="${target%%/Caskroom/*}/Caskroom/$name/.metadata/INSTALL_RECEIPT.json"
      kind="cask"
      official_tap="homebrew/cask"
      ;;
    */Cellar/*)
      rest="${target#*/Cellar/}"
      name="${rest%%/*}"
      rest="${rest#*/}"
      receipt="${target%%/Cellar/*}/Cellar/$name/${rest%%/*}/INSTALL_RECEIPT.json"
      kind="formula"
      official_tap="homebrew/core"
      ;;
    *) return 1 ;;
  esac

  [[ -n "$name" ]] || return 1
  [[ "$(jq -r '.source.tap // empty' "$receipt" 2>/dev/null)" == "$official_tap" ]] || return 1
  printf '%s/%s\n' "$kind" "$name"
}

# Prints the version Homebrew currently publishes for an
# atrium_official_homebrew_package path — what `brew upgrade` moves to.
atrium_homebrew_published_version() {
  local package="${1:-}" api_json=""
  api_json="$(curl -fsS --connect-timeout 2 --max-time 5 "https://formulae.brew.sh/api/$package.json" 2>/dev/null)" || return 1
  printf '%s' "$api_json" | jq -er '(.version // .versions.stable) | select(type == "string" and length > 0)' 2>/dev/null
}

# Follows every symlink hop of a path (bash 3.2 and BSD readlink have no -f).
atrium_resolve_symlinks() {
  local path="${1:-}" link="" hops=0
  while [[ -L "$path" && "$hops" -lt 40 ]]; do
    link="$(readlink "$path" 2>/dev/null)" || break
    case "$link" in
      /*) path="$link" ;;
      *) path="${path%/*}/$link" ;;
    esac
    hops=$((hops + 1))
  done
  printf '%s\n' "$path"
}

# mise detection is structural, never via $MISE_DATA_DIR: check_update runs
# with only the boot PATH while the updateCommand gets the login-shell env, and
# the two must classify a binary the same way.
atrium_binary_is_mise_shim() {
  local binary_path="${1:-}" target=""
  case "$binary_path" in
    */mise/shims/*) return 0 ;;
    */shims/*) ;;
    *) return 1 ;;
  esac
  target="$(atrium_resolve_symlinks "$binary_path")"
  [[ "$target" != "$binary_path" && "${target##*/}" == mise ]]
}

# Prints "<mise data dir>/installs/<tool dir>" when the binary, or what it links
# to, lives inside a mise install: the default layout, or any directory holding
# the backend record mise writes beside each tool's versions.
atrium_mise_install_dir() {
  local candidate="" rest="" dir=""
  for candidate in "${1:-}" "$(atrium_resolve_symlinks "${1:-}")"; do
    case "$candidate" in
      */mise/installs/*)
        rest="${candidate#*/mise/installs/}"
        printf '%s\n' "${candidate%%/mise/installs/*}/mise/installs/${rest%%/*}"
        return 0
        ;;
    esac
    dir="$candidate"
    while [[ "${dir%/*}" != "$dir" ]]; do
      dir="${dir%/*}"
      if [[ -f "$dir/.mise.backend.toml" || -f "$dir/.mise.backend" ]]; then
        printf '%s\n' "$dir"
        return 0
      fi
    done
  done
  return 1
}

# $MISE_DATA_DIR when set, else the data dir the binary's own path implies.
atrium_mise_data_dir() {
  local binary_path="${1:-}" install_dir=""
  if [[ -n "${MISE_DATA_DIR:-}" ]]; then
    printf '%s\n' "$MISE_DATA_DIR"
  elif install_dir="$(atrium_mise_install_dir "$binary_path")"; then
    printf '%s\n' "${install_dir%/installs/*}"
  elif atrium_binary_is_mise_shim "$binary_path"; then
    printf '%s\n' "${binary_path%/shims/*}"
  else
    return 1
  fi
}

# Prints a callable mise: the one on PATH, else the mise binary a shim links to.
atrium_mise_command() {
  local binary_path="${1:-}" candidate=""
  if candidate="$(command -v mise 2>/dev/null)" && [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  atrium_binary_is_mise_shim "$binary_path" || return 1
  candidate="$(atrium_resolve_symlinks "$binary_path")"
  [[ "${candidate##*/}" == mise && -x "$candidate" ]] || return 1
  printf '%s\n' "$candidate"
}

# atrium_mise_exec <binary path> <mise> <args...>: runs mise from $HOME — the
# context the updateCommand bumps — against the binary's data dir.
atrium_mise_exec() {
  local binary_path="${1:-}" mise_bin="${2:-}" data_dir=""
  shift 2
  data_dir="$(atrium_mise_data_dir "$binary_path")" || data_dir=""
  if [[ -n "$data_dir" ]]; then
    (cd "$HOME" 2>/dev/null && MISE_DATA_DIR="$data_dir" "$mise_bin" "$@" 2>/dev/null)
  else
    (cd "$HOME" 2>/dev/null && "$mise_bin" "$@" 2>/dev/null)
  fi
}

# node/bun installs also host `npm install -g` packages; npm owns those, not a
# mise tool pin.
atrium_mise_tool_is_runtime() {
  case "${1:-}" in
    node | nodejs | bun | core:node | core:bun) return 0 ;;
  esac
  return 1
}

# Prints the mise tool id `mise upgrade --bump` takes for a mise-owned binary
# (e.g. "npm:@openai/codex"). Fails for binaries mise doesn't own and for npm
# globals hosted by a mise runtime. Prefers the tool mise resolves from $HOME
# — what the updateCommand bumps — over the install dir's recorded backend.
atrium_mise_tool_for_binary() {
  local binary_path="${1:-}" binary="${2:-}" install_dir="" mise_bin="" tool=""

  if install_dir="$(atrium_mise_install_dir "$binary_path")"; then
    atrium_mise_tool_is_runtime "${install_dir##*/}" && return 1
  elif ! atrium_binary_is_mise_shim "$binary_path"; then
    return 1
  fi

  if mise_bin="$(atrium_mise_command "$binary_path")"; then
    tool="$(atrium_mise_exec "$binary_path" "$mise_bin" which --plugin "$binary")" || tool=""
  fi
  if [[ -z "$tool" && -n "$install_dir" ]]; then
    tool="$(sed -n 's/^short = "\(.*\)"$/\1/p' "$install_dir/.mise.backend.toml" 2>/dev/null | sed -n '1p')"
    [[ -n "$tool" ]] || tool="${install_dir##*/}"
  fi

  [[ -n "$tool" ]] || return 1
  atrium_mise_tool_is_runtime "$tool" && return 1
  printf '%s\n' "$tool"
}

# The binary mise runs from $HOME. A login-shell PATH captured before a
# `mise upgrade` still names the old version's install dir, which mise keeps
# until it prunes it.
atrium_mise_current_binary() {
  local path=""
  path="$(atrium_mise_exec "${1:-}" "${2:-}" which "${3:-}")" || return 1
  [[ -n "$path" ]] || return 1
  printf '%s\n' "$path"
}

# The newest version `mise upgrade --bump` would install — it honours the
# user's minimum_release_age, so it can trail the registry's latest.
atrium_mise_latest_version() {
  MISE_FETCH_REMOTE_VERSIONS_TIMEOUT="${MISE_FETCH_REMOTE_VERSIONS_TIMEOUT:-5s}" \
    atrium_mise_exec "${1:-}" "${2:-}" latest "${3:-}"
}
