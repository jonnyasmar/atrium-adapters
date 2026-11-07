import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

export function buildDigest(bytes) {
  const source = JSON.parse(bytes);
  const models = {};
  for (const name of Object.keys(source).sort()) {
    const row = source[name];
    if (row.mode !== 'chat' || !/^(claude-|gpt-|o[134](?:-|$)|grok-|gemini-|deepseek-|kimi-|muse-)/i.test(name)) continue;
    const rates = Object.fromEntries(Object.entries(row).filter(([key, value]) =>
      /^(input_cost_per_token|output_cost_per_token|cache_read_input_token_cost|cache_creation_input_token_cost)(_|$)/.test(key)
      && typeof value === 'number' && Number.isFinite(value) && value >= 0));
    if (rates.input_cost_per_token === undefined || rates.output_cost_per_token === undefined) continue;
    models[name] = rates;
  }
  return {
    v: 1,
    version: createHash('sha256').update(bytes).digest('hex'),
    source: 'https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json',
    license: 'MIT',
    models,
  };
}

if (process.argv[1]?.endsWith('build-digest.mjs')) {
  const [input, output] = process.argv.slice(2);
  if (!input || !output) throw new Error('usage: node build-digest.mjs <LiteLLM table.json> <digest.json>');
  writeFileSync(output, JSON.stringify(buildDigest(readFileSync(input)), null, 2) + '\n');
}
