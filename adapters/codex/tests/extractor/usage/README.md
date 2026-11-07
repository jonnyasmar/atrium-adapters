# Synthetic Codex usage fixtures

Every value is invented. Keys are the owning session ID and cumulative total_tokens. A root, sibling forks, and a grandchild repeat inherited history; ordinal boundaries resolve ownership at each ancestor. Folding this family gives two root requests and one new request each for child-a, child-b, and grandchild: 545 disjoint tokens in total. Cached input is subtracted; reasoning is a subset of output.

The test also compresses these invented files in memory and checks archive replay and replacement. Compressed rollouts use a `z:size:mtime_ns:trailer_crc32` checkpoint; plain JSONL uses `o:offset:previous_line_crc32`. Archive reads use Python 3.14 stdlib zstd or the optional zstandard module, with no per-file subprocess. An unavailable decompressor is an explicit incomplete checkpoint.
