import math

from extract_session_usage import count


def legacy_events(usage, session, identity, at):
    models = usage.get('modelUsage')
    models = models if isinstance(models, dict) and models else {'__none': usage}
    events = []
    for model, counters in models.items():
        if not isinstance(counters, dict):
            continue
        cached = count(counters.get('cachedReadTokens', counters.get('cacheReadInputTokens')))
        written = count(counters.get('cacheCreationTokens', counters.get('cacheCreationInputTokens')))
        input_tokens = count(counters.get('inputTokens'))
        output = count(counters.get('outputTokens'))
        if cached + written > input_tokens:
            raise ValueError('cache tokens exceed inclusive input')
        cost = None
        if not counters.get('costIsPartial'):
            ticks = counters.get('costUsdTicks')
            reported = counters.get('costUSD')
            if isinstance(ticks, int) and not isinstance(ticks, bool) and ticks >= 0:
                cost = ticks / 1e10
            elif isinstance(reported, (int, float)) and not isinstance(reported, bool) and math.isfinite(reported) and reported >= 0:
                cost = reported
        events.append(dict(type='usage', at=at, session_id=session, model=model,
                           dedupe=f'grok-turn:{session}:{identity}:{model}',
                           tokens=dict(input=input_tokens-cached-written, output=output,
                                       cache_read=cached, cache_write_5m=written, cache_write_1h=0,
                                       reasoning=min(output, count(counters.get('reasoningTokens')))),
                           cost_usd=cost))
    return events
