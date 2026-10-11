#!/usr/bin/env bash
set -euo pipefail

skill="skills/atrium-bug-report/SKILL.md"

require() {
  local pattern="$1"
  local message="$2"
  if ! grep -Eq "$pattern" "$skill"; then
    echo "atrium-bug-report contract: $message" >&2
    exit 1
  fi
}

reject() {
  local pattern="$1"
  local message="$2"
  if grep -Eq "$pattern" "$skill"; then
    echo "atrium-bug-report contract: $message" >&2
    exit 1
  fi
}

require 'atrium-contract-reviewed-through: [0-9a-f]{40}' 'missing full atrium review marker'
require 'runtime\.<YYYY-MM-DD>\.log.*background daemon \(`atriumd`\)' 'runtime log ownership drifted'
require 'chat-runtime\.<YYYY-MM-DD>\.log' 'chat-runtime log is absent from the artifact map'
for artifact in video.mov transcript.jsonl events.jsonl chapters.json annotations.json; do
  require "$artifact" "capture bundle inventory is missing $artifact"
done
require 'issues/new\?title=<urlencoded-title>&body=<urlencoded-approved-body>' 'fallback must preserve the approved issue body'
require 'Never shell out to `ffmpeg`, `ffprobe`, `sips`, or ImageMagick' 'capture investigation must require atrium native commands'
require 'mktemp .*atrium-issue\.XXXXXX' 'issue drafts must use an exclusive per-run temporary file'
require 'APPROVED_SHA256=' 'posting must bind the approval to the complete draft bytes'
require 'ACTUAL_SHA256=' 'posting must verify the complete draft bytes immediately before gh'
require 'body-file.*ISSUE_DRAFT' 'gh must post from the exclusive per-run draft'
require 'chat-restore-failure' 'handled chat restore failures must be discoverable'
require 'startup-day.*file' 'surviving sidecar stderr must not imply midnight rotation'
require 'Screenshot/chunk.*macOS-only' 'capture extraction must state its platform boundary'
require 'Any trimming is a draft revision' 'fallback edits must go through approval again'

reject 'labels=bug,source:in-app' 'fallback still assumes unprovisioned labels'
reject 'for L in bug source:in-app' 'posting still silently mutates an unprovisioned taxonomy'
reject '^## `area:` labels|— `area:' 'unprovisioned area labels have returned'
reject 'typical busy day logs|~15,000 INFO' 'static log-volume calibration has returned'
reject '/tmp/atrium-issue\.md' 'fixed issue-draft paths allow concurrent sessions to swap bodies'
reject '90% of the (file|volume)' 'static stderr-volume assumptions have returned'
reject 'cef.log.*\*\*only\*\* place' 'browser host failures also reach the app log'

echo "atrium-bug-report contract: ok"
