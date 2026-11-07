CREATE TABLE session_message (
  id TEXT PRIMARY KEY NOT NULL,
  session_id TEXT NOT NULL,
  type TEXT NOT NULL,
  seq INTEGER NOT NULL,
  time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE TABLE session_v2 (
  id TEXT PRIMARY KEY NOT NULL,
  fork_session_id TEXT,
  fork_boundary TEXT
);
CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message(session_id, seq);
CREATE INDEX session_message_session_time_created_id_idx ON session_message(session_id, time_created, id);

INSERT INTO session_v2 VALUES ('ses_synthetic_opencode_716', NULL, NULL);

INSERT INTO session_message VALUES
('msg_synthetic_assistant_001', 'ses_synthetic_opencode_716', 'assistant', 1, 1794000001123, 1794000001123,
 '{"agent":"build","model":{"id":"claude-opus-4-6","providerID":"anthropic"},"tokens":{"input":100,"output":40,"reasoning":15,"cache":{"read":20,"write":7}},"time":{"created":1794000001123,"completed":1794000002456}}'),
('msg_synthetic_compaction_completed', 'ses_synthetic_opencode_716', 'compaction', 2, 1794000002456, 1794000002456,
 '{"status":"completed","reason":"auto","model":{"id":"gemini-2.5-pro","providerID":"google"},"tokens":{"input":11,"output":4,"reasoning":2,"cache":{"read":3,"write":1}},"time":{"created":1794000002456}}'),
('msg_synthetic_compaction_failed', 'ses_synthetic_opencode_716', 'compaction', 3, 1794000003456, 1794000003456,
 '{"status":"failed","reason":"manual","error":{"name":"SyntheticError","message":"invented fixture failure"},"tokens":{"input":1,"output":2,"reasoning":3,"cache":{"read":0,"write":0}},"time":{"created":1794000003456}}'),
('msg_synthetic_compaction_running', 'ses_synthetic_opencode_716', 'compaction', 4, 1794000003567, 1794000003567,
 '{"status":"running","reason":"auto","summary":"synthetic running compaction","tokens":{"input":999,"output":999,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1794000003567}}'),
('msg_synthetic_assistant_no_usage', 'ses_synthetic_opencode_716', 'assistant', 5, 1794000004000, 1794000004000,
 '{"agent":"build","model":{"id":"synthetic-model","providerID":"synthetic"},"content":[],"time":{"created":"2026-11-06T21:20:04.000Z"}}'),
('msg_synthetic_user', 'ses_synthetic_opencode_716', 'user', 6, 1794000005000, 1794000005000,
 '{"text":"synthetic user message","time":{"created":"2026-11-06T21:20:05.000Z"}}'),
('msg_synthetic_assistant_tie', 'ses_synthetic_opencode_716', 'assistant', 7, 1794000001789, 1794000002456,
 '{"agent":"build","model":{"id":"synthetic-visible-model","providerID":"synthetic"},"tokens":{"input":10,"output":6,"reasoning":1,"cache":{"read":0,"write":0}},"time":{"created":1794000001789}}');
