#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Grok sessions for a CWD.
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive}, ...]}
#
# Grok stores sessions at ~/.grok/sessions/<url-encoded-cwd>/<session-uuid>/.
# Each session dir contains summary.json which we parse for id, name, lastActive.

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"

CWD="$CWD" perl -e '
sub iso_from_epoch {
  my ($second, $minute, $hour, $day, $month, $year) = gmtime($_[0]);
  return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", $year + 1900, $month + 1, $day, $hour, $minute, $second);
}

my $cwd = $ENV{CWD} // "/";
my $encoded = join "", map {
  my $char = chr($_);
  $char =~ /[A-Za-z0-9]/ ? $char : sprintf("%%%02X", $_)
} unpack("C*", $cwd);
my $project_dir = ($ENV{HOME} // "") . "/.grok/sessions/$encoded";
opendir my $dir, $project_dir or do {
  print "{\"sessions\": []}\n";
  exit 0;
};

my @sessions;
for my $entry (readdir $dir) {
  next if $entry eq "." || $entry eq "..";
  my $filepath = "$project_dir/$entry/summary.json";
  next unless -f $filepath;
  open my $fh, "<", $filepath or next;
  local $/;
  my $blob = <$fh>;
  close $fh;

  my ($kind) = $blob =~ /"session_kind"\s*:\s*"([^"]+)"/;
  my ($parent_id) = $blob =~ /"parent_session_id"\s*:\s*"([^"]+)"/;
  next if (defined($kind) && ($kind eq "subagent" || $kind eq "subagent_resume"))
    || (defined($parent_id) && $parent_id ne "");
  my $mtime = (stat($filepath))[9] // next;
  push @sessions, { filepath => $filepath, blob => $blob, mtime => $mtime };
}
closedir $dir;
@sessions = sort { $b->{mtime} <=> $a->{mtime} } @sessions;
splice @sessions, 20 if @sessions > 20;

my @items;
for my $session (@sessions) {
  my $filepath = $session->{filepath};
  my $blob = $session->{blob};
  my $mtime = $session->{mtime};

  # session id from the parent dir name
  my ($sid) = $filepath =~ m{/([^/]+)/summary\.json$};
  $sid //= "unknown";

  my ($id_val, $cwd_val, $title, $last_active) = ("", "", "", "");
  # Crude field extraction avoids a JSON module startup penalty.
  ($id_val) = $blob =~ /"id"\s*:\s*"([^"]+)"/;
  ($cwd_val) = $blob =~ /"cwd"\s*:\s*"([^"]+)"/;
  ($title) = $blob =~ /"generated_title"\s*:\s*"([^"]+)"/;
  ($title) = $blob =~ /"session_summary"\s*:\s*"([^"]+)"/ unless $title;
  ($last_active) = $blob =~ /"last_active_at"\s*:\s*"([^"]+)"/;
  $last_active ||= ($blob =~ /"updated_at"\s*:\s*"([^"]+)"/)[0] // "";

  $id_val ||= $sid;
  $cwd_val ||= $cwd;

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
  my $iso = $last_active ne "" ? $last_active : iso_from_epoch($mtime);
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
