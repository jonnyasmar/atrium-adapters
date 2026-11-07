# Prospective live usage capture assessment

Assessed 2026-11-07 from atrium source and official provider documentation.
Assessment only: no transport, journal, runtime, or manifest capability changes.
No new billable turns or raw user transcripts were captured. Historical native
transcript support and prospective journal support are separate decisions.

Paths below are relative to the atrium app repo. `transports/` abbreviates
`sidecars/chat-runtime/src/transports/`. Sizes are engineering estimates after
lane I's common journal plumbing exists: S = about 1–2 engineering days,
M = 3–5, L = more than 5 or an upstream dependency. These are not measured
implementation times. Payload estimates are noted separately below.

| Adapter | What atrium sees today / granularity | Capture seam and missing work | Prospective verdict / size |
| --- | --- | --- | --- |
| Copilot | The manifest selects `copilot --acp`, **not** the SDK event transport. Generic ACP context/end-turn handlers exist, but no handler or bridge receives `assistant.usage`. Terminal hooks carry activity and completion, not an SDK usage subscription. The official SDK supplies per-API-call usage; its aggregates cannot replace that feed. | A future SDK transport/bridge must subscribe to `assistant.usage` before mapping UI events, retaining session, event/call identity, model, timestamp, cache/reasoning and child attribution. Current `transports/acp.ts::handleMessage` / `completeTurn` are the ACP seams, not proof that SDK fields arrive there. Prove an ACP extension or add the SDK path first. | Conditional candidate; **L** if adding an SDK transport, **M** if a verified per-call ACP extension exists. No support claim for today's ACP or terminal integration. |
| Antigravity | Current managed ACP server logs Gemini-shaped usage on stderr. `parseAntigravityUsage` reads prompt, cached and total counts, keeps only the last match in each chunk, and cannot recover split objects. `handleAntigravityUsage` emits context occupancy and drops cache detail. This is a best-effort meter, without request identity/completion guarantees. Google's separate headless stream has per-step usage, plus a result aggregate. | `transports/acpRpcClient.ts` stderr callback → `acpAntigravity.ts::parseAntigravityUsage` → `acp.ts::handleAntigravityUsage`. Capturing the existing meter is insufficient. Prefer a structured completion feed; a headless transport would need final-step identity/model/time mapping, reconnect dedupe, checkpoint-call semantics and child attribution. The terminal normalizer currently scrapes reply text, not request usage. | Possible future source; **L** for a reliable structured path. A small stderr tweak is not enough to mark Supported. |
| Cursor | Current chat uses ACP. Prior app probe (2026-07-30, not rerun) recorded no usage and a bare stop response. Current official ACP/output docs establish no per-model-call usage stream. The old probe saw usage only on print-mode terminal results; a run result still does not establish individual model requests. | `transports/acp.ts::handleMessage` / `completeTurn`, once Cursor exposes verified request facts. Terminal output/hooks do not currently forward such facts. Do not infer them from context estimates, durations or a print result. | No verified candidate on current transport; **L / upstream dependency**. Reprobe new versions before implementing. |
| Hermes | ACP context `usage_update` is an estimate; `session/prompt` returns usage from the finished `run_conversation` result. This is end-of-turn information, not a complete per-model-call stream, and cannot establish request count when tools cause multiple calls. Current atrium uses it for occupancy. | `transports/acp.ts::completeTurn` / `mapEndTurnUsage` is where the end-turn data arrives. Hermes upstream `acp_adapter/server.py::_finish_turn` builds it and `_build_usage_update` estimates context. Add a verified upstream per-model-completion notification/callback bridge, then normalize before UI reduction. | Existing wire data insufficient; **L** for upstream/bridge work. Journal persistence alone cannot restore missing calls. |
| Muse | **Yes:** `session/tokenUsage` already reaches `museMsp.ts::handleTokenUsage`. Vendored `muse/mspSchema.ts::SessionTokenUsageParams` specifies one event per model completion, modelId, sessionId, turnId, sourceRange/viewCursor, raw usage and counted-once promptTokens/totalTokens. Today `emitUsage` throws away identity and most counters. `turn/completed.usage`, cumulative totals and child totals are aggregates and must not be counted again. | Capture in `handleTokenUsage` before `emitUsage`. Preserve opaque source identity for dedupe/replay and the provider-normalized prompt count; validate cache/reasoning conventions. The event has no completion timestamp, so establish a contract-approved live observation timestamp or recover the durable completion time. Handle null legacy models honestly. Children need their own completion stream; never expand child aggregates. | Strong candidate; **M** including timestamp contract, dedupe/replay, cache tests and truthful child coverage. It may also justify reopening native-format research: the generated schema explicitly says these events derive from durable records. |

## Common journal work

Use lane I's canonical request-usage journal event, separate from the current
`usage-update` context-meter event. The latter is lossy and movement-filtered:
equal token totals from two different requests must both survive. Persist the
canonical fact before any UI coalescing, dedupe by provider identity across replay
and reconnect, and feed the usage helper's durable ingestion/retention path.
Do not turn a prompt/turn into a single request simply because it has a usage
summary. Never reconstruct historical missing calls from later cumulative totals.
`source: "journal"` would cover only captured sessions going forward; retain
Unsupported/partial coverage for unobserved history and terminal-only sessions.

Storage estimate, not measured traffic: allow roughly 0.5–1 KiB per normalized
request event including identity/journal envelope (about 5–10 MiB per 10,000
requests before compression). All five are O(requests) if a real request feed
exists. Copilot quota snapshots and raw Antigravity stderr may be much larger;
keep an allowlisted usage payload, never whole logs, text, prompts or tool output.
Exact provider payload sizes were not measured because no live capture was run.

## Evidence and limits

- Copilot: [usage/billing](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/usage-and-billing),
  [streaming event schema](https://github.com/github/copilot-sdk/blob/main/docs/features/streaming-events.md),
  [ACP server](https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server).
- Antigravity: [headless output](https://antigravity.google/docs/cli/headless),
  [ACP transport](https://antigravity.google/docs/cli/acp).
- Cursor: [ACP](https://cursor.com/docs/cli/acp),
  [output format](https://cursor.com/docs/cli/reference/output-format).
  Prior local observation: app `claudedocs/context-meter-transport-coverage.md`;
  treat its July probe as dated evidence, not a fresh live verification.
- Hermes: [official ACP implementation](https://github.com/NousResearch/hermes-agent/blob/main/acp_adapter/server.py).
- Muse: [audit contract](https://dev.meta.ai/docs/cookbook/audit-agent-sessions)
  describes durable model-call logging, but is not the detailed counter schema;
  [changelog](https://dev.meta.ai/docs/muse-code/changelog) describes the separate
  run-level `muse exec --json` summaries. The stronger per-completion evidence is
  the app's generated vendor contract `muse/mspSchema.ts` (exported with
  `muse schema generate-ts`), not an inference from run summaries.

None of these findings changes the two adapters' Unsupported native capability.
Lane H owns the synchronized manifest/`BUILT_IN_USAGE_ADAPTERS` capability set and
paired release version bumps. The absence of these two adapters in both sets is
intentional. A future support promotion needs its own capture fixtures and tests.
