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

INSERT INTO session_v2 VALUES
('ses_fork_parent', NULL, NULL),
('ses_fork_child', 'ses_fork_parent', '{"type":"through","messageID":"msg_000000000000abcdefghijklmn"}'),
('ses_sibling_a', 'ses_deleted_parent', '{"type":"through","messageID":"msg_000000000000missingparent"}'),
('ses_sibling_b', 'ses_deleted_parent', '{"type":"through","messageID":"msg_000000000000missingparent"}'),
('ses_surviving_grandparent', NULL, NULL),
('ses_grandchild_after_delete', 'ses_deleted_intermediate', '{"type":"through","messageID":"msg_000000000000deletedinter"}');

INSERT INTO session_message VALUES
('msg_000000000000abcdefghijklmn', 'ses_fork_parent', 'assistant', 1, 1794000001000, 1794000001000,
 '{"model":{"id":"synthetic-parent-model"},"tokens":{"input":20,"output":10,"reasoning":2,"cache":{"read":3,"write":1}},"time":{"created":1794000001000}}'),
('msg_000000000000opqrstuvwxyzAB_1', 'ses_fork_child', 'assistant', 1, 1794000001000, 1794000001000,
 '{"model":{"id":"synthetic-parent-model"},"tokens":{"input":20,"output":10,"reasoning":2,"cache":{"read":3,"write":1}},"time":{"created":1794000001000}}'),
('msg_000000000000CDEFGHIJKLMNOP', 'ses_fork_child', 'assistant', 2, 1794000002000, 1794000002000,
 '{"model":{"id":"synthetic-child-model"},"tokens":{"input":7,"output":4,"reasoning":1,"cache":{"read":0,"write":0}},"time":{"created":1794000002000}}'),
('msg_000000000000qrstuvwxyzABCD_1', 'ses_sibling_a', 'assistant', 1, 1794000003000, 1794000003000,
 '{"model":{"id":"synthetic-copy-model"},"tokens":{"input":30,"output":15,"reasoning":4,"cache":{"read":5,"write":2}},"time":{"created":1794000003000}}'),
('msg_000000000000STUVWXYZabcdef_1', 'ses_sibling_b', 'assistant', 1, 1794000003000, 1794000003000,
 '{"model":{"id":"synthetic-copy-model"},"tokens":{"input":30,"output":15,"reasoning":4,"cache":{"read":5,"write":2}},"time":{"created":1794000003000}}'),
('msg_000000000000zyxwvutsrqponm', 'ses_surviving_grandparent', 'assistant', 1, 1794000004000, 1794000004000,
 '{"model":{"id":"synthetic-grandparent-model"},"tokens":{"input":40,"output":20,"reasoning":5,"cache":{"read":6,"write":3}},"time":{"created":1794000004000}}'),
('msg_000000000000efghijklmnopQR_1', 'ses_grandchild_after_delete', 'assistant', 1, 1794000004000, 1794000004000,
 '{"model":{"id":"synthetic-grandparent-model"},"tokens":{"input":40,"output":20,"reasoning":5,"cache":{"read":6,"write":3}},"time":{"created":1794000004000}}');
