#!/usr/bin/env python3
"""Print the last assistant message text from a Cursor chat store.db.

Cursor's `cursor-agent` CLI fires no hook event carrying the assistant's
response text (`afterAgentResponse` is IDE-only), so atrium's stop hook pulls
it out-of-band from the chat sqlite. Reuses extract_session.py's decode helpers
(same dir) so the message-blob handling stays in one place.

Usage:
  last-assistant-message.py --cwd <cwd>   # resolve the active session's store.db
  last-assistant-message.py --db <path>   # read a specific store.db (tests)

Prints the last assistant message to stdout (empty on any miss — the caller
treats absence as "leave lastAssistantMessage null"). Never raises.
"""
import argparse
import hashlib
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract_session import (  # noqa: E402  (path is set above)
    _decode_message,
    _flatten_content,
    _open_ro,
    _try_read_messages,
)


def _newest_store_db(cwd: str):
    """The active session is the most-recently-written store.db under the
    cwd's workspace hash dir (`md5(realpath(cwd))`, mirroring Cursor)."""
    try:
        resolved = os.path.realpath(cwd)
    except OSError:
        resolved = cwd
    workspace_hash = hashlib.md5(resolved.encode("utf-8")).hexdigest()
    root = os.path.join(os.path.expanduser("~/.cursor/chats"), workspace_hash)
    if not os.path.isdir(root):
        return None
    newest = None
    newest_mtime = -1.0
    for entry in os.listdir(root):
        db = os.path.join(root, entry, "store.db")
        try:
            mtime = os.path.getmtime(db)
        except OSError:
            continue
        if mtime > newest_mtime:
            newest, newest_mtime = db, mtime
    return newest


def _scan(conn):
    """Return (last_assistant_text, last_message_role) from the chat store in
    iteration (chronological) order — so the caller can tell whether the most
    recent message is the assistant's reply or still the user's prompt."""
    last_text = ""
    last_role = None
    for _key, value in _try_read_messages(conn):
        msg = _decode_message(value)
        if not isinstance(msg, dict):
            continue
        role = msg.get("role") or msg.get("type")
        if role:
            last_role = role
        if role == "assistant":
            text = _flatten_content(msg.get("content") or msg.get("text"))
            if text and text.strip():
                last_text = text.strip()
    return last_text, last_role


def last_assistant_message(db_path: str) -> str:
    # Cursor fires its stop hook around the moment the reply is written to the
    # chat store; if the write lags the hook, the newest row is still the user
    # prompt and we'd return the PREVIOUS turn's reply ("one behind" — the same
    # race fixed for the file-scraping adapters). Poll (bounded, well under the
    # hook timeout) until the newest message is the assistant reply, then return
    # it. When the reply is already present this returns on the first read.
    budget_s = 1.6
    interval_s = 0.12
    deadline = time.monotonic() + budget_s
    last = ""
    while True:
        try:
            conn = _open_ro(db_path)
        except Exception:
            return last
        try:
            last, last_role = _scan(conn)
        except Exception:
            last_role = None
        finally:
            try:
                conn.close()
            except Exception:
                pass
        if last_role == "assistant" or time.monotonic() >= deadline:
            return last
        time.sleep(interval_s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cwd")
    ap.add_argument("--db")
    args = ap.parse_args()

    db = args.db or (_newest_store_db(args.cwd or os.getcwd()))
    if not db or not os.path.isfile(db):
        return
    text = last_assistant_message(db)
    if text:
        sys.stdout.write(text)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never break the stop hook — absence just leaves lastMessage null.
        pass
