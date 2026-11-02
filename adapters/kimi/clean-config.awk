# clean-config.awk — print kimi's config.toml without anything atrium wrote.
#
#   awk -v begin="<BEGIN marker>" -v end="<END marker>" -f clean-config.awk config.toml
#
# Drops, and nothing else:
#   - the managed block, BEGIN through END, when both markers are present in
#     that order (a BEGIN without an END removes only the marker line);
#   - any stray marker line;
#   - every [[hooks]] table whose keys name atrium's kimi hook script
#     (`atrium-runtime-hook` and `/adapters/kimi/kimi-hook.sh` on one line),
#     wherever it sits. kimi rewrites config.toml without comments on login,
#     so the markers vanish and atrium's tables move above the user's;
#   - the blank lines directly above anything dropped (atrium's separators:
#     every older install added one), and trailing blank lines.
# Lines inside multi-line strings are never headers, markers or blanks to drop.
# Prints how many lines it dropped beyond the managed block on stderr.

function is_blank(s) { return s ~ /^[[:space:]]*$/ }
function is_key(s) { return s ~ /^[[:space:]]*[A-Za-z0-9_."'-]+[[:space:]]*=/ }
function quotes(s,    count, rest, at) {
  count = 0
  rest = s
  while ((at = match(rest, /"""|'''/)) > 0) {
    count++
    rest = substr(rest, at + RLENGTH)
  }
  return count
}

{ line[++n] = $0 }

END {
  open = 0
  for (i = 1; i <= n; i++) {
    inside[i] = open
    if (quotes(line[i]) % 2 == 1) open = !open
  }

  first = 0
  last = 0
  for (i = 1; i <= n; i++) if (!inside[i] && line[i] == begin) { first = i; break }
  if (first) for (i = first + 1; i <= n; i++) if (!inside[i] && line[i] == end) { last = i; break }
  if (first && last) for (i = first; i <= last; i++) { drop[i] = 1; managed[i] = 1 }

  for (i = 1; i <= n; i++) {
    if (inside[i]) continue
    if (line[i] == begin || line[i] == end) drop[i] = 1
    if (line[i] !~ /^[[:space:]]*\[\[[[:space:]]*hooks[[:space:]]*\]\][[:space:]]*$/) continue
    stop = i
    while (stop < n && !inside[stop + 1] && is_key(line[stop + 1])) stop++
    ours = 0
    for (k = i + 1; k <= stop; k++) {
      if (index(line[k], "atrium-runtime-hook") && index(line[k], "/adapters/kimi/kimi-hook.sh")) ours = 1
    }
    if (ours) for (k = i; k <= stop; k++) drop[k] = 1
  }

  for (i = 1; i <= n; i++) {
    if (!drop[i] || (i > 1 && drop[i - 1])) continue
    for (k = i - 1; k >= 1 && !drop[k] && !inside[k] && is_blank(line[k]); k--) drop[k] = 1
  }
  for (k = n; k >= 1 && !inside[k] && (drop[k] || is_blank(line[k])); k--) drop[k] = 1

  extra = 0
  for (i = 1; i <= n; i++) {
    if (drop[i]) {
      if (!managed[i] && !(first && last && i == first - 1 && is_blank(line[i]))) extra++
      continue
    }
    print line[i]
  }
  print extra > "/dev/stderr"
}
