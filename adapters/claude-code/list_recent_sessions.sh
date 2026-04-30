#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Claude Code sessions for a CWD.
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive}, ...]}
#
# Performance: uses stat+sort+perl pipeline (~10ms for 20 files).
# Reads only the first 500 chars of each user message line to avoid
# parsing multi-MB image/multimodal payloads through jq.

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"
# Match Claude Code's project-dir encoding: leading '-', then '/', '.', and
# spaces all collapse to '-'. Without '.' and space handling, workspaces like
# '~/foo/.worktrees/bar' or '~/Developer/Personal Research' silently miss.
ENCODED="-${CWD#/}"
ENCODED="${ENCODED//\//-}"
ENCODED="${ENCODED//./-}"
ENCODED="${ENCODED// /-}"
PROJECT_DIR="${HOME}/.claude/projects/${ENCODED}"

if [ ! -d "$PROJECT_DIR" ]; then
  echo '{"sessions": []}'
  exit 0
fi

# Single stat → sort → top 20, then perl reads only what it needs
TOP="$(stat -f '%m %N' "$PROJECT_DIR"/*.jsonl 2>/dev/null | sort -rn | head -20)" || true
[ -z "$TOP" ] && { echo '{"sessions": []}'; exit 0; }

echo "$TOP" | CWD="$CWD" perl -e '
use POSIX qw(strftime);
my @items;
while (<STDIN>) {
  chomp;
  my ($mtime, $filepath) = split / /, $_, 2;
  next unless $filepath && -f $filepath;

  # basename without .jsonl extension
  my ($bn) = $filepath =~ m{/([^/]+)\.jsonl$};
  $bn //= "unknown";

  # Two-pass scan: head for first user message, tail for lastPrompt + user count
  my ($sid, $cwd_val, $first_msg, $last_prompt) = ("", "", "", "");
  my $user_count = 0;

  # Pass 1: first 80 lines for session ID, CWD, first real user message
  if (open my $fh, "<", $filepath) {
    for (1..80) {
      my $line = <$fh>;
      last unless defined $line;
      next unless $line =~ /"type"/ && $line =~ /"user"/;
      $user_count++;

      # Only need first 500 chars for field extraction — avoids
      # reading multi-MB image payloads into memory
      my $head = substr($line, 0, 500);
      ($sid) = $head =~ /"sessionId":"([^"]+)"/ if !$sid && $head =~ /sessionId/;
      ($cwd_val) = $head =~ /"cwd":"([^"]+)"/ if !$cwd_val && $head =~ /"cwd"/;

      # Skip if we already have a first message
      next if $first_msg ne "";

      my $raw = "";
      ($raw) = $head =~ /"text":"([^"]{1,300})/ if $head =~ /"text"/;
      ($raw) = $head =~ /"content":"([^"]{1,300})/ if !$raw && $head =~ /"content"/;
      next if $raw eq "";

      # Strip wrapper tags injected by skills/commands to find real user text
      # <command-message>...</command-message>\n<command-name>...</command-name>\n<command-args>REAL TEXT
      if ($raw =~ /<command-args>([^<]+)/) {
        my $args = $1;
        $args =~ s/^\s+//; $args =~ s/\s+$//;
        $first_msg = $args if $args ne "";
      }
      # <local-command-caveat>...</local-command-caveat> — skip entirely, grab next user msg
      elsif ($raw =~ /^<local-command-caveat>/) {
        next;
      }
      # <command-name>/foo</command-name> without useful args — skip, grab next real msg
      elsif ($raw =~ /^<command-(?:name|message)>/) {
        next;
      }
      # Normal user message
      else {
        $first_msg = $raw;
      }
    }
    close $fh;
  }

  # Pass 2: read last 4KB for lastPrompt and extra user messages
  my $fsize = -s $filepath || 0;
  if ($fsize > 0) {
    if (open my $fh2, "<", $filepath) {
      my $seek_pos = $fsize > 4096 ? $fsize - 4096 : 0;
      seek($fh2, $seek_pos, 0) if $seek_pos > 0;
      <$fh2> if $seek_pos > 0;  # discard partial first line
      while (my $line = <$fh2>) {
        if ($line =~ /"type"\s*:\s*"last-prompt"/) {
          my ($lp) = $line =~ /"lastPrompt"\s*:\s*"([^"]{1,200})/;
          $last_prompt = $lp if $lp;
        }
        $user_count++ if $line =~ /"type"/ && $line =~ /"user"/;
      }
      close $fh2;
    }
  }
  # For large files, approximate user count from file size (avoids full scan)
  if ($fsize > 100_000 && $user_count < 3) {
    # Heuristic: average ~2KB per message, ~40% are user messages
    $user_count = int($fsize / 5000) || 3;
  }

  $sid ||= $bn;
  $cwd_val ||= $ENV{CWD} // "/";

  # Build display name: combine first message + last prompt for richer context
  my $name_val = "";
  # Clean up first message
  if ($first_msg ne "") {
    $first_msg =~ s/\\n/ /g;
    $first_msg =~ s/\s+/ /g;
    $first_msg =~ s/^ //; $first_msg =~ s/ $//;
  }
  # Clean up last prompt
  if ($last_prompt ne "") {
    $last_prompt =~ s/\\n/ /g;
    $last_prompt =~ s/\s+/ /g;
    $last_prompt =~ s/^ //; $last_prompt =~ s/ $//;
  }

  if ($first_msg ne "" && $last_prompt ne "" && $last_prompt ne $first_msg && $user_count > 2) {
    # Multi-turn session: show first + last for context
    my $first_trunc = length($first_msg) > 50 ? substr($first_msg, 0, 47) . "..." : $first_msg;
    my $last_trunc = length($last_prompt) > 40 ? substr($last_prompt, 0, 37) . "..." : $last_prompt;
    $name_val = "$first_trunc \xe2\x80\xa2 Last: $last_trunc";
  } elsif ($first_msg ne "") {
    $name_val = length($first_msg) > 80 ? substr($first_msg, 0, 77) . "..." : $first_msg;
  } elsif ($last_prompt ne "") {
    $name_val = length($last_prompt) > 80 ? substr($last_prompt, 0, 77) . "..." : $last_prompt;
  }

  # JSON-escape
  $name_val =~ s/\\/\\\\/g;
  $name_val =~ s/"/\\"/g;
  $name_val =~ s/\t/\\t/g;
  $name_val =~ s/\n/\\n/g;
  $name_val =~ s/\r/\\r/g;

  my $iso = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($mtime));
  my $n = $name_val eq "" ? "null" : "\"$name_val\"";
  push @items, "{\"id\":\"$sid\",\"name\":$n,\"cwd\":\"$cwd_val\",\"lastActive\":\"$iso\"}";
}
print "{\"sessions\":[" . join(",", @items) . "]}\n";
'

exit 0
