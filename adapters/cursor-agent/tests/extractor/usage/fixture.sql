CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE messages (key INTEGER PRIMARY KEY, value TEXT);
INSERT INTO meta VALUES ('0', '7b226e616d65223a2253796e7468657469632063686174227d');
INSERT INTO messages VALUES
  (1, '{"role":"user","content":"Synthetic prompt","createdAt":1794000000000}'),
  (2, '{"role":"assistant","content":"Synthetic reply","createdAt":1794000001000}');
