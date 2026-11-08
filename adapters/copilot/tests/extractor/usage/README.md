# Copilot native usage: Unsupported

Verified 2026-11-07 against GitHub's official documentation:

- [Usage and billing metrics](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/usage-and-billing):
  `assistant.usage` describes individual model calls, including subagents, but is
  ephemeral and unavailable on resume. `session.usage.getMetrics` gives accumulated
  totals. A billing multiplier is not a dollar cost.
- [Streaming session events](https://github.com/github/copilot-sdk/blob/main/docs/features/streaming-events.md):
  ephemeral events are not persisted; `session.shutdown.modelMetrics` is a
  per-model summary and `session.usage_checkpoint` is durable aggregate accounting.

The native `session-state/<session>/events.jsonl` source therefore does not provide
verified per-request usage. Partial `assistant.message.outputTokens`, shutdown
summaries, quota/context snapshots, or differences between aggregates cannot
supply the missing request facts. The parser intentionally ignores every row.
See [live-capture assessment](live-capture-assessment.md) for the separate
prospective journal path; current atrium chat runs ACP, not the Copilot SDK.

## Fixture contract

Every record, identifier, timestamp, model name, and count under `input/` was
invented for this test. Nothing was copied or sanitised from a real transcript.
`invented-session` exercises native-shaped content and misleading aggregates;
`invented-live-decoy` deliberately places live-only shapes in a file. That decoy
is not evidence that a harness persists those events. Even it must emit no usage.
The empty `expected-usage.jsonl` is intentional.

`--usage --batch` accepts stdin JSONL, emits exactly one checkpoint per request,
and emits no `usage` rows. `--usage --list` enumerates transcript metadata, not
usage events. Successful empty extraction does **not** mean Supported: there is
no `sessionExtractor.usage` capability, and this adapter must stay outside
`BUILT_IN_USAGE_ADAPTERS` until a request-level source is verified.

Run `bash adapters/copilot/tests/extractor/usage/assert-usage.sh` or
`bash validate-adapter.sh adapters/copilot`. The shared runner checks the empty
golden, every line-boundary resume, torn tails, bad CRC/truncation resets,
unreadable-file isolation, discovery, compressed input when available, and a
200-file batch budget (50 ms/file maximum). Local assertions check capability
absence, discovery IDs/metadata/`--since`, ordered complete zero-event
checkpoints with no malformed records, and an empty batch.
