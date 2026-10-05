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
