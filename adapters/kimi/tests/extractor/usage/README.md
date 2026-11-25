# Kimi usage fixtures

The invented fixture follows local Kimi Code `agents/main/wire.jsonl` records inspected on 23 November 2026. Only `usage.record` is billable: `inputOther` is uncached input, `inputCacheRead` and `inputCacheCreation` are separate, and `output` is output. `context.append_loop_event` repeats those counters and `token_counting.*` reports context occupancy; neither is added. Models are preserved verbatim, including unpriced `kimi-code/k3`.

The shared extractor resumes at a validated byte offset. Request identity includes session, agent and byte position, so appending to a session never needs to recount its prefix. The scale fixture grows other sessions and earlier rows 10×/100× while one appended request causes one parser call. A second read without an append emits no usage.

The manifest's quick metadata extractor resolves implicit workspace paths directly using Kimi's installed `encodeWorkDirKey` algorithm (slug plus SHA-256 prefix); it does not scan the session index. Managed Desktop workspace paths are not inferred. Usage discovery reads both implicit and managed workspace transcripts directly by their source paths.
