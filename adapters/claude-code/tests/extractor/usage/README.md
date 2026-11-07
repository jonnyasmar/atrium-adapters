# Synthetic usage fixtures

All records are invented. The key is message.id + requestId. Repeated content blocks fold with per-field maximum tokens; metadata follows the larger total. Subagents use their parent session and the same request key space.

The parent contains an incomplete nested progress copy of the subagent request. Its non-sidechain flag must not replace the larger final subagent counters. ccusage 20.0.48 prefers that progress copy; this fixture keeps the final output count.
