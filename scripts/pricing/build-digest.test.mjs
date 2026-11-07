import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildDigest } from './build-digest.mjs';

test('keeps known tier/cache rates, rejects unrelated and invalid data, and hashes source', () => {
  const bytes = Buffer.from(JSON.stringify({
    'gpt-fixture': { mode: 'chat', input_cost_per_token: 1, output_cost_per_token: 2,
      input_cost_per_token_above_200k_tokens: 3, cache_creation_input_token_cost_above_1hr: 4,
      input_cost_per_token_priority: 5, max_tokens: 100, output_cost_per_token_fast: -1 },
    unrelated: { mode: 'image', input_cost_per_token: 1 },
  }));
  const digest = buildDigest(bytes);
  assert.deepEqual(Object.keys(digest.models), ['gpt-fixture']);
  assert.equal(digest.models['gpt-fixture'].cache_creation_input_token_cost_above_1hr, 4);
  assert.equal(digest.models['gpt-fixture'].input_cost_per_token_above_200k_tokens, 3);
  assert.equal(digest.models['gpt-fixture'].max_tokens, undefined);
  assert.equal(digest.models['gpt-fixture'].output_cost_per_token_fast, undefined);
  assert.equal(digest.version.length, 64);
  assert.equal(digest.version, buildDigest(bytes).version);
});
