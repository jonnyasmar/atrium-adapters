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
ENCODED="-${CWD#/}"
ENCODED="${ENCODED//\//-}"
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

  # Find first user-type message (up to 50 lines)
  my ($sid, $cwd_val, $name_val) = ("", "", "");
  if (open my $fh, "<", $filepath) {
    for (1..50) {
      my $line = <$fh>;
      last unless defined $line;
      next unless $line =~ /"type"/ && $line =~ /"user"/;
      # Only need first 500 chars for field extraction — avoids
      # reading multi-MB image payloads into memory
      my $head = substr($line, 0, 500);
      ($sid) = $head =~ /"sessionId":"([^"]+)"/ if $head =~ /sessionId/;
      ($cwd_val) = $head =~ /"cwd":"([^"]+)"/ if $head =~ /"cwd"/;
      ($name_val) = $head =~ /"text":"([^"]{1,200})/ if $head =~ /"text"/;
      ($name_val) = $head =~ /"content":"([^"]{1,200})/ if !$name_val && $head =~ /"content"/;
      last;
    }
    close $fh;
  }

  $sid ||= $bn;
  $cwd_val ||= $ENV{CWD} // "/";

  # Collapse whitespace and trim for display name
  if ($name_val ne "") {
    $name_val =~ s/\s+/ /g;
    $name_val =~ s/^ //;
    $name_val =~ s/ $//;
  }

  # JSON-escape
  $name_val =~ s/\\/\\\\/g;
  $name_val =~ s/"/\\"/g;
  $name_val =~ s/\t/\\t/g;
  $name_val =~ s/\n/\\n/g;
  $name_val =~ s/\r/\\r/g;
  $name_val = substr($name_val, 0, 47) . "..." if length($name_val) > 50;

  my $iso = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($mtime));
  my $n = $name_val eq "" ? "null" : "\"$name_val\"";
  push @items, "{\"id\":\"$sid\",\"name\":$n,\"cwd\":\"$cwd_val\",\"lastActive\":\"$iso\"}";
}
print "{\"sessions\":[" . join(",", @items) . "]}\n";
'

exit 0
