# Goose usage fixtures

Every row in `fixture.sql` is invented. The dedupe key is `goose:<session_id>:<usage_ledger.id>`; the ledger id is append-only. Goose's ledger stores prompt input inclusive of cached input, with cache read/write as subsets, so the emitted `input` subtracts both cache buckets. Goose stores cache writes without a TTL split, so they map to `cache_write_5m` as the contract directs. Reasoning is not recorded in the ledger and is emitted as zero.

Only `cost_source = 'provider_reported'` is preserved as `cost_usd`. `estimated` is deliberately null, and `carried_forward` rows are aggregate reconciliation records rather than provider calls and are omitted. The timestamp is the ledger's Unix-seconds `created_timestamp`, normalized to UTC milliseconds.

The fixture database is built from this synthetic SQL at test time. No real Goose session database or transcript is used.

Primary sources:

- https://github.com/aaif-goose/goose/blob/main/crates/goose/src/session/session_manager.rs (migration 15, ledger schema, per-call insert, and carried-forward reconciliation)
- https://github.com/aaif-goose/goose/blob/main/crates/goose-provider-types/src/conversation/token_usage.rs (input includes cached tokens; cache counters are subsets)
- https://github.com/aaif-goose/goose/blob/main/crates/goose/src/providers/canonical_cost.rs (provider-reported versus estimated cost semantics)
