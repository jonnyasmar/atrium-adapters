CREATE TABLE message (
  id TEXT PRIMARY KEY NOT NULL,
  session_id TEXT NOT NULL,
  time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX message_time_updated_idx ON message(time_updated, id);

INSERT INTO message VALUES
('msg_legacy_original', 'ses_a_origin', 1794000001123, 1794000002456,
 '{"role":"assistant","modelID":"claude-opus-4-6","providerID":"anthropic","tokens":{"input":100,"output":40,"reasoning":15,"cache":{"read":20,"write":7}},"cost":99,"time":{"created":1794000001123,"completed":1794000002456}}'),
('msg_legacy_fork_copy', 'ses_z_fork', 1794000020000, 1794000021000,
 '{"role":"assistant","modelID":"claude-opus-4-6","providerID":"anthropic","tokens":{"input":100,"output":40,"reasoning":15,"cache":{"read":20,"write":7}},"cost":99,"time":{"created":1794000001123,"completed":1794000002456}}'),
('msg_legacy_parallel_a', 'ses_parallel_a', 1794000003127, 1794000004127,
 '{"role":"assistant","modelID":"gpt-5","providerID":"openai","tokens":{"input":101,"output":5,"reasoning":2,"cache":{"read":3,"write":0}},"time":{"created":1794000003127,"completed":1794000004127}}'),
('msg_legacy_parallel_b', 'ses_parallel_b', 1794000003127, 1794000004127,
 '{"role":"assistant","modelID":"gpt-5","providerID":"openai","tokens":{"input":102,"output":5,"reasoning":2,"cache":{"read":3,"write":0}},"time":{"created":1794000003127,"completed":1794000004127}}'),
('msg_legacy_unknown_model', 'ses_model_not_reported', 1794000005129, 1794000006129,
 '{"role":"assistant","tokens":{"input":8,"output":4,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1794000005129,"completed":1794000006129}}'),
('msg_legacy_user', 'ses_a_origin', 1794000000123, 1794000000123,
 '{"role":"user","modelID":"gpt-5","tokens":{"input":9000},"time":{"created":1794000000123}}'),
('msg_legacy_incomplete', 'ses_streaming', 1794000007131, 1794000008131,
 '{"role":"assistant","modelID":"gpt-5","tokens":{"input":30,"output":2,"reasoning":1,"cache":{"read":0,"write":0}},"time":{"created":1794000007131}}'),
('msg_legacy_shell', 'ses_shell', 1794000009133, 1794000010133,
 '{"role":"assistant","modelID":"gpt-5","tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1794000009133,"completed":1794000010133}}'),
('msg_legacy_no_usage', 'ses_no_usage', 1794000011135, 1794000012135,
 '{"role":"assistant","modelID":"gpt-5","time":{"created":1794000011135,"completed":1794000012135}}');
