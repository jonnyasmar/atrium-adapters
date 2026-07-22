#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Grok sessions for a CWD.
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive}, ...]}
#
# Grok stores sessions at ~/.grok/sessions/<url-encoded-cwd>/<session-uuid>/.
# Each session dir contains summary.json which we parse for id, name, lastActive.

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"

# URL-encode the cwd path the way grok does: slashes become %2F.
ENCODED="$(printf '%s' "$CWD" | perl -MURI::Escape -e 'print uri_escape(<STDIN>, "^A-Za-z0-9");' 2>/dev/null)"
if [ -z "$ENCODED" ]; then
  # Fallback if URI::Escape unavailable: minimal manual encoding (slash → %2F).
  ENCODED="${CWD//\//%2F}"
fi

PROJECT_DIR="${HOME}/.grok/sessions/${ENCODED}"

if [ ! -d "$PROJECT_DIR" ]; then
  echo '{"sessions": []}'
  exit 0
fi

# Find session dirs, sort by mtime of summary.json, take top 20.
TOP="$(
  perl -e '
    for my $path (@ARGV) {
      next unless -f $path;
      my $mtime = (stat($path))[9] // next;
      print "$mtime $path\n";
    }
  ' "$PROJECT_DIR"/*/summary.json 2>/dev/null | sort -rn | head -20
)" || true
[ -z "$TOP" ] && { echo '{"sessions": []}'; exit 0; }

echo "$TOP" | CWD="$CWD" perl -e '
use POSIX qw(strftime);
my @items;
while (<STDIN>) {
  chomp;
  my ($mtime, $filepath) = split / /, $_, 2;
  next unless $filepath && -f $filepath;

  # session id from the parent dir name
  my ($sid) = $filepath =~ m{/([^/]+)/summary\.json$};
  $sid //= "unknown";

  my ($id_val, $cwd_val, $title, $last_active) = ("", "", "", "");

  if (open my $fh, "<", $filepath) {
    local $/;
    my $blob = <$fh>;
    close $fh;
    # crude field extraction — avoids depending on jq inside perl
    ($id_val) = $blob =~ /"id"\s*:\s*"([^"]+)"/;
    ($cwd_val) = $blob =~ /"cwd"\s*:\s*"([^"]+)"/;
    ($title) = $blob =~ /"generated_title"\s*:\s*"([^"]+)"/;
    ($title) = $blob =~ /"session_summary"\s*:\s*"([^"]+)"/ unless $title;
    ($last_active) = $blob =~ /"last_active_at"\s*:\s*"([^"]+)"/;
    $last_active ||= ($blob =~ /"updated_at"\s*:\s*"([^"]+)"/)[0] // "";
  }

  $id_val ||= $sid;
  $cwd_val ||= $ENV{CWD} // "/";

  my $name_val = $title;
  if ($name_val ne "") {
    $name_val =~ s/\\/\\\\/g;
    $name_val =~ s/"/\\"/g;
    $name_val =~ s/\t/\\t/g;
    $name_val =~ s/\n/\\n/g;
    $name_val =~ s/\r/\\r/g;
    $name_val = substr($name_val, 0, 80);
  }

  # Prefer ISO from summary; fall back to mtime if missing.
  my $iso = $last_active ne "" ? $last_active : strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($mtime));
  my $n = $name_val eq "" ? "null" : "\"$name_val\"";

  # Escape cwd for JSON
  $cwd_val =~ s/\\/\\\\/g;
  $cwd_val =~ s/"/\\"/g;

  my $source_path = $filepath;
  $source_path =~ s{/summary\.json$}{/chat_history.jsonl};
  $source_path = $filepath unless -f $source_path;
  $source_path =~ s/\\/\\\\/g;
  $source_path =~ s/"/\\"/g;

  push @items, "{\"id\":\"$id_val\",\"name\":$n,\"cwd\":\"$cwd_val\",\"lastActive\":\"$iso\",\"sourcePath\":\"$source_path\"}";
}
print "{\"sessions\":[" . join(",", @items) . "]}\n";
'

exit 0
