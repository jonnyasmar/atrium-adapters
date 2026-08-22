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
