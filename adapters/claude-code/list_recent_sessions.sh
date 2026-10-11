#!/usr/bin/env bash
set -euo pipefail

# list_recent_sessions.sh — List recent Claude Code sessions for a CWD.
# Takes $1 = CWD
# Output: {"sessions": [{id, name, cwd, lastActive, sourcePath}, ...]}
#
# name is the session title Claude Code shows: the latest custom-title (a
# /rename), else ai-title, else summary. Untitled sessions fall back to the
# first real prompt, with the last prompt appended for multi-turn sessions.
#
# Performance: one stat+sort pass, then perl reads the first 80 lines and the
# last 64 KB of each of the 20 newest transcripts (the same head/tail split
# Claude Code uses for its /resume list). Lines are searched as raw bytes and
# only the values used are decoded, so multi-MB image lines stay cheap.

CWD="${1:?Usage: list_recent_sessions.sh <cwd>}"
# Match Claude Code's project-dir encoding (mP() in its CLI bundle): every
# UTF-16 code unit outside [a-zA-Z0-9] becomes '-' (so an astral char like an
# emoji becomes two), and an encoding over 200 chars is cut to 200 and
# suffixed with '-' + base36(|int32 Java-style string hash of the raw path|).
ENCODED="$(CWD="$CWD" perl -e '
  my $p = $ENV{CWD};
  utf8::decode($p);
  my @units = map {
    my $c = ord;
    $c > 0xFFFF ? (0xD800 + (($c - 0x10000) >> 10), 0xDC00 + (($c - 0x10000) & 0x3FF)) : $c
  } split //, $p;
  my $enc = join "", map { chr($_) =~ /^[a-zA-Z0-9]$/ ? chr($_) : "-" } @units;
  if (length($enc) > 200) {
    my $h = 0;
    $h = ($h * 31 + $_) % 4294967296 for @units;  # (h<<5)-h+unit, mod 2^32
    $h = 4294967296 - $h if $h >= 2147483648;     # abs() of it as a signed int32
    my $b36 = "";
    do { $b36 = (0..9, "a".."z")[$h % 36] . $b36; $h = int($h / 36) } while $h;
    $enc = substr($enc, 0, 200) . "-$b36";
  }
  print $enc;
')"
PROJECT_DIR="${HOME}/.claude/projects/${ENCODED}"

if [ ! -d "$PROJECT_DIR" ]; then
  echo '{"sessions": []}'
  exit 0
fi

# Single stat → sort → top 20, then perl reads only what it needs
TOP="$(
  perl -e '
    for my $path (@ARGV) {
      next unless -f $path;
      my $mtime = (stat($path))[9] // next;
      print "$mtime $path\n";
    }
  ' "$PROJECT_DIR"/*.jsonl 2>/dev/null | sort -rn | head -20
)" || true
[ -z "$TOP" ] && { echo '{"sessions": []}'; exit 0; }

echo "$TOP" | CWD="$CWD" perl -e '
use strict;
use warnings;
no warnings "utf8";
use POSIX qw(strftime);

# Everything below works on decoded characters, never raw bytes: labels are
# truncated by grapheme, so a CJK or emoji character is never cut in half, and
# the reply is encoded back to UTF-8 exactly once, at print time.
# NOTE: this body is a single-quoted shell string, so no apostrophes in here.

my $HEAD_LINES = 80;      # head scan: session id, cwd, first real prompt
my $TAIL_BYTES = 65536;   # tail scan: latest title records and last prompt
my $PREAMBLE = "This session is being continued from a previous conversation";
my %ESC = (n => "\n", t => "\t", r => "\r", b => "\x08", f => "\x0c", u => "");

# utf8::decode alone is lax: it accepts encoded surrogates (\xED\xA0\x80)
# and code points past U+10FFFF, which strict decoders reject. So any non-ASCII
# value keeps only well-formed UTF-8 runs and drops every other byte (a torn
# write, a window edge, or bytes some other tool wrote) before decoding.
sub decode_text {
  my ($s) = @_;
  return $s unless $s =~ /[\x80-\xff]/;
  $s =~ s/((?:[\x00-\x7f]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf]{2}|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2})+)|[\x80-\xff]/defined $1 ? $1 : ""/ge;
  utf8::decode($s);
  return $s;
}

sub code_point {
  my ($cp) = @_;
  return ($cp >= 0xD800 && $cp <= 0xDFFF) ? "\x{FFFD}" : chr($cp);
}

# Undo JSON string escaping once. Left to right, one escape at a time, so an
# escaped backslash is never re-read as the start of another escape.
sub json_unescape {
  my ($s) = @_;
  $s =~ s{\\(?:u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][c-fC-F][0-9a-fA-F]{2})|u([0-9a-fA-F]{4})|(.))}{
    defined $1 ? chr(0x10000 + ((hex($1) - 0xD800) << 10) + (hex($2) - 0xDC00))
    : defined $3 ? code_point(hex $3)
    : exists $ESC{$4} ? $ESC{$4} : $4
  }gse;
  return $s;
}

# Transcript lines are searched as raw bytes, through $_[0] rather than a
# copy: a head line can be megabytes (a pasted image), and copying or
# validating it whole costs as much as a scan. Only the value is decoded.
#
# The JSON string starting at byte offset $_[1], read from a 2 KB window:
# far more than any label shows, and a character torn by the window edge is
# dropped by decode_text, never emitted half.
sub string_at {
  my $window = substr($_[0], $_[1], 2048);
  $window =~ /\A([^"\\]*+(?:\\.[^"\\]*+)*+)/s;
  return json_unescape(decode_text($1));
}

sub field {
  my $key = $_[1];
  return undef unless $_[0] =~ /"\Q$key\E"\s*:\s*"/g;
  my $at = pos($_[0]);
  pos($_[0]) = undef;
  return string_at($_[0], $at);
}

# cwd and sessionId are trailing keys, written after a message that can be
# megabytes, so only the last 4 KB of a record is searched for them.
sub trailing_field {
  my $key = $_[1];
  return field($_[0], $key) if length($_[0]) <= 4096;
  my $end = substr($_[0], -4096);
  return field($end, $key);
}

sub tidy {
  my ($s) = @_;
  return "" unless defined $s;
  $s =~ s/[\x00-\x1f\x7f\s]+/ /g;
  $s =~ s/^ //;
  $s =~ s/ $//;
  return $s;
}

# Measured and cut in graphemes, so an emoji sequence counts once either way.
sub clip {
  my ($s, $max) = @_;
  my @graphemes = $s =~ /(\X)/g;
  return $s if @graphemes <= $max;
  my $head = join "", @graphemes[0 .. $max - 2];
  $head =~ s/ $//;
  return $head . "\x{2026}";
}

sub json_str {
  my ($s) = @_;
  $s =~ s/\\/\\\\/g;
  $s =~ s/"/\\"/g;
  $s =~ s/\n/\\n/g;
  $s =~ s/\r/\\r/g;
  $s =~ s/\t/\\t/g;
  $s =~ s/([\x00-\x1f\x7f])/sprintf("\\u%04x", ord($1))/ge;
  return "\"$s\"";
}

# The human prompt a user record carries, or undef for the turns Claude Code
# writes itself: compaction summaries and the continuation preamble, harness
# tags (local-command caveats, system reminders, task notifications), and
# interrupt markers. A slash command counts through its arguments; a bare one
# is only remembered as a last-resort label. atrium wraps voice-dictated spans
# in <dictated> tags; those are the human prompt, so they are unwrapped.
sub prompt_text {
  my ($text, $command_fallback) = @_;
  my $t = substr($text, 0, 1000);
  $t =~ s{</?dictated>}{}g;
  $t = tidy($t);
  return undef if $t eq "" || index($t, $PREAMBLE) == 0;
  if ($t =~ m{<command-name>\s*([^<]*?)\s*</command-name>}) {
    my $name = $1;
    my ($args) = $t =~ m{<command-args>\s*([^<]*?)\s*(?:</command-args>|$)};
    return $args if defined $args && $args ne "";
    $$command_fallback = $name if $name ne "" && !defined $$command_fallback;
    return undef;
  }
  return "! " . tidy($1) if $t =~ m{<bash-input>(.*?)</bash-input>};
  return undef if $t =~ /^<[a-z][\w-]*[\s>\/]/;
  return undef if $t =~ /^\[Request interrupted by user[^\]]*\]$/;
  return $t;
}

sub user_prompt {
  my $command_fallback = $_[1];
  my $at = index($_[0], q{"message"});
  $at = index($_[0], q{"content"}, $at < 0 ? 0 : $at);
  return undef if $at < 0;
  pos($_[0]) = $at;
  return undef unless $_[0] =~ /\G"content"\s*:\s*([\["])/g;
  my $prompt;
  if ($1 eq "\"") {
    $prompt = prompt_text(string_at($_[0], pos($_[0])), $command_fallback);
  } else {
    # A tool result names its type in its first block, right after the bracket.
    return undef if index(substr($_[0], pos($_[0]), 512), q{"tool_result"}) >= 0;
    while ($_[0] =~ /"text"\s*:\s*"/g) {
      $prompt = prompt_text(string_at($_[0], pos($_[0])), $command_fallback);
      last if defined $prompt;
    }
  }
  pos($_[0]) = undef;
  # These flags sit after the message, so looking for them scans the whole
  # line: only done for the one line that would otherwise label the session.
  return undef if defined $prompt
    && (index($_[0], q{"isMeta":true}) >= 0 || index($_[0], q{"isCompactSummary":true}) >= 0);
  return $prompt;
}

# Session metadata records lead with their type. custom-title (a /rename),
# ai-title and summary are last-wins, as Claude Code reads them, and an empty
# custom title clears an earlier rename.
my $METADATA_RECORD = qr/^\{\s*"type"\s*:\s*"(custom-title|ai-title|summary|last-prompt)"/;
my %METADATA_KEY = ("custom-title" => "customTitle", "ai-title" => "aiTitle",
                    "summary" => "summary", "last-prompt" => "lastPrompt");

sub note_metadata {
  my ($kind, $titles) = @_[1, 2];
  my $value = field($_[0], $METADATA_KEY{$kind});
  $titles->{$kind} = tidy($value) if defined $value;
}

# The top-level type sits in the first few hundred bytes of a record; message
# content can only come after it, so a nested "type" is never mistaken for it.
my $USER_RECORD = qr/"type"\s*:\s*"user"/;

my @items;
while (my $entry = <STDIN>) {
  chomp $entry;
  my ($mtime, $filepath) = split / /, $entry, 2;
  next unless $filepath && -f $filepath;

  my ($bn) = $filepath =~ m{/([^/]+)\.jsonl$};
  $bn //= "unknown";

  my ($sid, $cwd_val, $first_msg, $command_fallback) = ("", "", undef, undef);
  my (%head_titles, %tail_titles);
  my $user_count = 0;

  if (open my $fh, "<:raw", $filepath) {
    for (1 .. $HEAD_LINES) {
      my $line = <$fh>;
      last unless defined $line;
      if (substr($line, 0, 48) =~ $METADATA_RECORD) {
        note_metadata($line, $1, \%head_titles);
        next;
      }
      $sid = trailing_field($line, "sessionId") // "" if $sid eq "";
      $cwd_val = trailing_field($line, "cwd") // "" if $cwd_val eq "";
      next unless substr($line, 0, 1024) =~ $USER_RECORD;
      $user_count++;
      $first_msg = user_prompt($line, \$command_fallback) unless defined $first_msg;
    }
    close $fh;
  }

  my $fsize = -s $filepath || 0;
  if ($fsize > 0 && open my $fh, "<:raw", $filepath) {
    my $seek_pos = $fsize > $TAIL_BYTES ? $fsize - $TAIL_BYTES : 0;
    if ($seek_pos > 0) {
      # Discard the partial first line, unless the window starts on a line.
      seek($fh, $seek_pos - 1, 0);
      read($fh, my $before, 1);
      <$fh> if $before ne "\n";
    }
    while (my $line = <$fh>) {
      if (substr($line, 0, 48) =~ $METADATA_RECORD) {
        note_metadata($line, $1, \%tail_titles);
      } elsif ($seek_pos > 0 && substr($line, 0, 1024) =~ $USER_RECORD) {
        $user_count++;
      }
    }
    close $fh;
  }
  # For large files, approximate user count from file size (avoids full scan)
  if ($fsize > 100_000 && $user_count < 3) {
    # Heuristic: average ~2KB per message, ~40% are user messages
    $user_count = int($fsize / 5000) || 3;
  }

  # The tail is later in the file than the head, so its records win.
  my %latest = (%head_titles, %tail_titles);
  my ($title) = grep { defined $_ && $_ ne "" }
    @latest{qw(custom-title ai-title summary)};
  my $last_prompt = $latest{"last-prompt"} // "";
  $first_msg //= $command_fallback // "";

  my $name_val = "";
  if (defined $title) {
    $name_val = clip($title, 80);
  } elsif ($first_msg ne "" && $last_prompt ne "" && $last_prompt ne $first_msg && $user_count > 2) {
    # Multi-turn session: show first + last for context
    $name_val = clip($first_msg, 50) . " \x{2022} Last: " . clip($last_prompt, 40);
  } elsif ($first_msg ne "") {
    $name_val = clip($first_msg, 80);
  } elsif ($last_prompt ne "") {
    $name_val = clip($last_prompt, 80);
  }

  my $path_val = decode_text($filepath);
  $sid = $sid ne "" ? $sid : decode_text($bn);
  $cwd_val = $cwd_val ne "" ? $cwd_val : decode_text($ENV{CWD} // "/");

  my $iso = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($mtime));
  push @items, "{\"id\":" . json_str($sid)
    . ",\"name\":" . ($name_val eq "" ? "null" : json_str($name_val))
    . ",\"cwd\":" . json_str($cwd_val)
    . ",\"lastActive\":\"$iso\""
    . ",\"sourcePath\":" . json_str($path_val) . "}";
}
my $out = "{\"sessions\":[" . join(",", @items) . "]}\n";
utf8::encode($out);
print $out;
'

exit 0
