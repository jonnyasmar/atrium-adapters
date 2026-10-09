#!/usr/bin/env bash

atrium_config_target() {
  local target="$1" link directory hops=0
  while [ -L "$target" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 40 ]; then
      echo "atrium hooks: config symlink cycle: $1" >&2
      return 1
    fi
    link="$(readlink "$target")" || return
    case "$link" in
      /*) target="$link" ;;
      *) target="$(dirname "$target")/$link" ;;
    esac
  done
  directory="$(cd -P "$(dirname "$target")" && pwd -P)" || return
  printf '%s/%s\n' "$directory" "$(basename "$target")"
}

atrium_config_temp() {
  local target tmp
  target="$(atrium_config_target "$1")" || return
  tmp="$(mktemp "${target}.atrium-tmp.XXXXXX")" || return
  # Carry the target's permissions before the producer writes the replacement.
  if [ -f "$target" ] && ! cp -p "$target" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

atrium_config_commit() {
  local tmp="$1" target
  target="$(atrium_config_target "$2")" || { rm -f "$tmp"; return 1; }
  if cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$target"
  fi
}
