CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  input_tokens INTEGER,
  output_tokens INTEGER,
  cache_read_tokens INTEGER,
  cache_write_tokens INTEGER,
  reasoning_tokens INTEGER,
  api_call_count INTEGER
);
CREATE TABLE messages (
  id INTEGER PRIMARY KEY,
  session_id TEXT,
  role TEXT,
  token_count INTEGER,
  timestamp REAL
);
CREATE TABLE session_model_usage (
  session_id TEXT,
  model TEXT,
  billing_provider TEXT,
  task TEXT,
  api_call_count INTEGER,
  input_tokens INTEGER,
  output_tokens INTEGER,
  cache_read_tokens INTEGER,
  cache_write_tokens INTEGER,
  reasoning_tokens INTEGER,
  first_seen REAL,
  last_seen REAL,
  PRIMARY KEY (session_id, model, billing_provider, task)
);
INSERT INTO sessions VALUES ('synthetic-hermes', 1000, 220, 400, 25, 80, 7);
INSERT INTO messages VALUES (1, 'synthetic-hermes', 'assistant', 64, 1794000000.0);
INSERT INTO session_model_usage VALUES
  ('synthetic-hermes', 'synthetic-model', 'synthetic-provider', '', 7, 1000, 220, 400, 25, 80, 1793990000, 1794000000);
