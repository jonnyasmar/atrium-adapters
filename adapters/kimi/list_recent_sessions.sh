#!/usr/bin/env bash
set -euo pipefail

REQUESTED_CWD="${1:-$PWD}"
KIMI_HOME="${KIMI_CODE_HOME:-$HOME/.kimi-code}"
INDEX_PATH="${KIMI_HOME}/session_index.jsonl"

if [[ ! -f "$INDEX_PATH" ]]; then
  printf '{"sessions":[]}\n'
  exit 0
fi

perl -MJSON::PP -MCwd=abs_path -e '
  use strict;
  use warnings;

  my ($index_path, $requested_cwd) = @ARGV;
  my $json = JSON::PP->new->utf8->canonical;
  my $resolved_requested = abs_path($requested_cwd) // $requested_cwd;
  my %latest;

  open my $index, "<", $index_path or do {
    print $json->encode({sessions => []}), "\n";
    exit 0;
  };
  while (my $line = <$index>) {
    my $record = eval { $json->decode($line) };
    next unless ref($record) eq "HASH";
    my $id = $record->{sessionId} // next;
    if ($record->{deleted}) {
      delete $latest{$id};
    } else {
      $latest{$id} = $record;
    }
  }
  close $index;

  my @sessions;
  for my $id (keys %latest) {
    my $entry = $latest{$id};
    my $session_dir = $entry->{sessionDir} // next;
    my $state_path = "$session_dir/state.json";
    next unless -f $state_path;

    open my $state_file, "<", $state_path or next;
    local $/;
    my $state_text = <$state_file>;
    close $state_file;
    my $state = eval { $json->decode($state_text) };
    next unless ref($state) eq "HASH";

    my $cwd = $state->{workDir} // $entry->{workDir} // "";
    my $resolved_cwd = abs_path($cwd) // $cwd;
    next unless $resolved_cwd eq $resolved_requested;

    my $name = $state->{title} // $state->{lastPrompt} // "Kimi session";
    $name =~ s/\s+/ /g;
    $name = substr($name, 0, 80);
    my $wire_path = "$session_dir/agents/main/wire.jsonl";
    my $source_path = -f $wire_path ? $wire_path : $state_path;
    my $mtime = (stat($state_path))[9] // 0;

    push @sessions, {
      id => $id,
      name => $name,
      cwd => $cwd,
      lastActive => ($state->{updatedAt} // $state->{createdAt} // ""),
      sourcePath => $source_path,
      _mtime => $mtime,
    };
  }

  @sessions = sort { $b->{_mtime} <=> $a->{_mtime} } @sessions;
  splice @sessions, 20 if @sessions > 20;
  delete $_->{_mtime} for @sessions;
  print $json->encode({sessions => \@sessions}), "\n";
' "$INDEX_PATH" "$REQUESTED_CWD"
