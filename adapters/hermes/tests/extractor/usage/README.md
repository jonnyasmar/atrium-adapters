# Hermes local usage limitation

This fixture is fully synthetic and contains cumulative `sessions` counters, a scalar `messages.token_count`, and one grouped `session_model_usage` row. The upstream schema documentation describes `session_model_usage` as per-model attribution; the writer accumulates deltas into a primary key of `(session_id, model, billing_provider, billing_base_url, billing_mode, task)` and retains `api_call_count`, `first_seen`, and `last_seen`, but no individual request id or timestamp. It also seeds the table from historic session aggregates.

That grouping cannot recover request-level times or rows. This adapter therefore has no `sessionExtractor.usage` manifest block and emits no usage events. It must not turn `messages.token_count` or session totals into requests.

Primary sources:

- https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/session-storage.md
- https://github.com/NousResearch/hermes-agent/blob/main/hermes_state_usage.py
- https://github.com/NousResearch/hermes-agent/blob/main/hermes_state_schema.py

The SQL values here are invented and are never taken from a local Hermes database.
