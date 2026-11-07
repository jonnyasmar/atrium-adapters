CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL DEFAULT '',
  working_dir TEXT NOT NULL,
  created_at TEXT,
  updated_at TEXT
);
CREATE TABLE usage_ledger (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  created_timestamp INTEGER NOT NULL,
  model TEXT,
  input_tokens INTEGER,
  output_tokens INTEGER,
  total_tokens INTEGER,
  cache_read_tokens INTEGER,
  cache_write_tokens INTEGER,
  cost REAL,
  cost_source TEXT,
  is_compaction INTEGER DEFAULT 0
);
INSERT INTO sessions (id, name, working_dir) VALUES
  ('synthetic-session', 'Synthetic usage', '/synthetic/project');
INSERT INTO usage_ledger (
  id, session_id, created_timestamp, model, input_tokens, output_tokens,
  total_tokens, cache_read_tokens, cache_write_tokens, cost, cost_source, is_compaction
) VALUES
  (11, 'synthetic-session', 1794000000, 'provider/model-alpha', 190, 40, 230, 100, 20, 0.0125, 'provider_reported', 0),
  (12, 'synthetic-session', 1794000001, NULL, 10, 3, 13, 0, 0, 0.5, 'estimated', 0),
  (13, 'synthetic-session', 1794000002, 'provider/model-alpha', 180, 35, 215, 90, 10, 0.01, 'carried_forward', 0);
