#!/usr/bin/env bash
set -euo pipefail
adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for mode in auto yolo; do
  case "$mode" in auto) expected=--yolo ;; yolo) expected=--auto ;; esac
  flags="$(jq -cn --arg mode "$mode" '{permissionMode:$mode}')"
  "$adapter_dir/build_launch_command.sh" "$flags" | jq -e --arg flag "$expected" '.command == ["kimi", $flag]' >/dev/null
  "$adapter_dir/build_resume_command.sh" test-session "$flags" | jq -e --arg flag "$expected" '.command == ["kimi", "--session", "test-session", $flag]' >/dev/null
done
for flags in '{"yolo":true}' '{"dangerouslySkipPermissions":true}'; do
  "$adapter_dir/build_launch_command.sh" "$flags" | jq -e '.command == ["kimi", "--auto"]' >/dev/null
done
jq -e '.options[] | select(.key == "yolo") | .description == "--auto"' "$adapter_dir/launcher_options.json" >/dev/null
