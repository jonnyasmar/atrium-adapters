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

# Write UPDATED (plus a newline) to CONFIG unless it equals ORIGINAL, the
# content the caller read and derived UPDATED from. Comparing against what was
# read, not what is on disk now, keeps a no-op pass from writing back a stale
# copy over an edit another program made in the meantime.
atrium_config_replace() {
  local config="$1" original="$2" updated="$3" tmp
  [ "$updated" = "$original" ] && return 0
  tmp="$(atrium_config_temp "$config")" || return
  if ! printf '%s\n' "$updated" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  atrium_config_commit "$tmp" "$config"
}

# Cross-process lock around a config read-modify-write. Every atrium instance
# (stable, dev, a remote daemon) runs these scripts against the same HOME, so
# an in-process mutex is not enough. The lock file holds the owner's PID; a
# lock whose owner is gone is taken over. Released on exit or by
# atrium_config_unlock.
ATRIUM_CONFIG_LOCK=""

atrium_config_lock() {
  local lock="$1" attempts=0 owner current
  [ -d "${lock%/*}" ] || mkdir -p "${lock%/*}"
  until (set -o noclobber; printf '%s\n' "$$" > "$lock") 2>/dev/null; do
    owner=""
    { read -r owner < "$lock"; } 2>/dev/null || true
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
      current=""
      { read -r current < "$lock"; } 2>/dev/null || true
      if [ "$current" = "$owner" ]; then
        rm -f "$lock"
        continue
      fi
    elif [ -z "$owner" ] && [ -n "$(find "$lock" -mmin +1 2>/dev/null)" ]; then
      # Owner died between creating the file and writing its PID.
      rm -f "$lock"
      continue
    fi

    attempts=$((attempts + 1))
    if [ "$attempts" -ge 600 ]; then
      echo "atrium hooks: timed out waiting for config lock: $lock" >&2
      return 1
    fi
    sleep 0.05
  done

  ATRIUM_CONFIG_LOCK="$lock"
  trap atrium_config_unlock EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

atrium_config_unlock() {
  local owner=""
  [ -n "$ATRIUM_CONFIG_LOCK" ] || return 0
  { read -r owner < "$ATRIUM_CONFIG_LOCK"; } 2>/dev/null || true
  if [ "$owner" = "$$" ]; then
    rm -f "$ATRIUM_CONFIG_LOCK"
  fi
  ATRIUM_CONFIG_LOCK=""
}
