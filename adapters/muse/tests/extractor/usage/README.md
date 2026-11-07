# Muse usage support status

Muse is intentionally unsupported by the transcript usage extractor. All records in the fixture are invented and use the locally documented durable envelope shape; it contains no model response or per-request usage fact. The existing prose extractor must continue to parse those durable records without emitting any `usage` event.

Meta's [session audit contract](https://dev.meta.ai/docs/cookbook/audit-agent-sessions) documents durable session-log envelopes and audit/runtime events, but no per-request token usage schema. The [Muse changelog](https://dev.meta.ai/docs/muse-code/changelog) documents `muse exec --json` `run.usage` as run-level usage by model plus subscription allowance. That is an ephemeral run aggregate, not a durable per-request transcript record, so this adapter does not advertise batch usage extraction and does not synthesize request events from aggregates.
