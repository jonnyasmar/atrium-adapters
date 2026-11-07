# Synthetic Codex usage fixtures

Every value is invented. Keys are the owning session ID and cumulative total_tokens. A root, sibling forks, and a grandchild repeat inherited history; ordinal boundaries resolve ownership at each ancestor. Folding this family gives two root requests and one new request each for child-a, child-b, and grandchild: 545 disjoint tokens in total. Cached input is subtracted; reasoning is a subset of output.

The test also compresses these invented files in memory and checks archive replay and replacement. Compressed rollouts use a `z:size:mtime_ns:trailer_crc32` checkpoint; plain JSONL uses `o:offset:previous_line_crc32`. Archive reads use Python 3.14 stdlib zstd or the optional zstandard module, with no per-file subprocess. An unavailable decompressor is an explicit incomplete checkpoint.

Sibling and grandchild copies have later timestamps than their ancestors. `expected-merged.jsonl` pins the final UTC-millisecond timestamps in both scan orders: equal totals retain the earlier record and its model/tier.

The invented forks use `source.subagent.thread_spawn.parent_thread_id`. Inherited events retain the owning ancestor's subagent flag, agent ID and fork parent, including the grandchild's copy of child-a's usage.

For paginated forks without an ordinal boundary, the additional synthetic tests remove the boundary from the invented family and compare both complete token-usage objects against the parent sequence. The longest matching prefix retains ancestor ownership; equal cumulative totals with different last-token usage end the prefix. A missing parent produces an incomplete checkpoint with `fork-ancestry-unavailable:<count>` and preserves the previous resume token. Adding the invented parent later resolves the same unchanged child.

Inherited keys absent from the ancestor rollout retain the family key but credit the child, with the ancestor in fork_of. Equal totals and times choose the smaller session id so sibling scan order is immaterial. Unreported models use __none and remain unpriced. Recorded thread settings preserve priority across later context records and resume boundaries.
