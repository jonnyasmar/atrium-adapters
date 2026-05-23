#!/usr/bin/env python3
"""Rebuild the cursor-agent fixture SQLite database from scratch.

The fixture mirrors Cursor's actual on-disk shape: a `meta` table with
hex-encoded JSON in row key='0', plus a `messages` table with plain
JSON values (the cursor decoder probes both encodings).

Run this to regenerate fixture-session.db if the schema needs to change.
Otherwise the committed .db file is the source of truth for CI tests.
"""
import json
import os
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, "fixture-session.db")

if os.path.exists(DB_PATH):
    os.remove(DB_PATH)

conn = sqlite3.connect(DB_PATH)
conn.executescript("""
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE messages (key INTEGER PRIMARY KEY, value TEXT);
""")

meta = {"agentId": "fixture-cur-001", "name": "list files in /tmp", "createdAt": 1748023200000}
meta_hex = json.dumps(meta).encode("utf-8").hex()
conn.execute("INSERT INTO meta(key,value) VALUES ('0', ?)", (meta_hex,))

messages = [
    {"role": "user", "content": "list files in /tmp", "createdAt": 1748023200000},
    {"role": "assistant", "content": "I'll run ls /tmp", "createdAt": 1748023201000,
     "toolCalls": [{"id": "cur_call_01", "name": "Bash", "input": {"command": "ls /tmp"}}]},
    {"role": "tool", "tool": "Bash", "tool_use_id": "cur_call_01", "content": "file1.txt\nfile2.txt\n",
     "createdAt": 1748023202000},
    {"role": "assistant", "content": "There are 2 files in /tmp", "createdAt": 1748023203000},
]
for i, m in enumerate(messages):
    conn.execute("INSERT INTO messages(key,value) VALUES (?,?)", (i, json.dumps(m)))
conn.commit()
conn.close()
print(f"Rebuilt {DB_PATH}", file=sys.stderr)
