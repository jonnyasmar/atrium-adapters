#!/usr/bin/env python3
"""Atrium Hermes adapter — config.yaml hook (de)registration + consent pre-seed.

Hermes reads shell hooks from the `hooks:` block of its config.yaml and gates
first use of each (event, command) pair behind a TTY consent prompt. This
helper:

  * edits ONLY the `hooks:` block, splicing a freshly-emitted block back into
    the original file so every other byte (comments, folded persona strings,
    quoting) is preserved verbatim, and
  * pre-seeds ~/.hermes/shell-hooks-allowlist.json with an approval per
    (event, command) so an atrium-launched `hermes chat` never blocks on the
    first-use prompt.

A YAML library (ruamel.yaml or pyyaml) is used only to parse and re-emit the
small `hooks:` subtree — never to re-serialize the whole document.

Subcommands:
  install   <config> <allowlist> <marker> <events_json>
  uninstall <config> <allowlist> <marker>
  status    <config> <marker>

`marker` is a substring identifying atrium-owned hook commands (the
hermes-hook.sh path). `events_json` is a JSON array of {event, command, timeout}.
"""
import datetime
import json
import os
import re
import sys
import tempfile

HOOKS_KEY_RE = re.compile(r"^hooks:\s*(.*)$")
AUTO_ACCEPT_RE = re.compile(r"^hooks_auto_accept:")


def _now_iso():
    return (
        datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    )


def _is_map(x):
    return hasattr(x, "get") and hasattr(x, "items")


# --------------------------------------------------------------------------
# YAML subtree parse / emit (only the `hooks:` block ever passes through here)
# --------------------------------------------------------------------------

def _yaml_load(text):
    try:
        from ruamel.yaml import YAML
        import io

        y = YAML(typ="safe")
        return y.load(io.StringIO(text))
    except Exception:
        import yaml as _pyyaml

        return _pyyaml.safe_load(text)


def _yaml_dump_lines(obj):
    """Dump `obj` ({"hooks": {...}}) and return its lines without a trailing
    newline. Block style, 2-space indent — matches Hermes's own config."""
    try:
        from ruamel.yaml import YAML
        import io

        y = YAML()
        y.default_flow_style = False
        y.allow_unicode = True
        y.width = 4096
        buf = io.StringIO()
        y.dump(obj, buf)
        text = buf.getvalue()
    except Exception:
        import yaml as _pyyaml

        text = _pyyaml.safe_dump(
            obj, sort_keys=False, default_flow_style=False, allow_unicode=True
        )
    return text.rstrip("\n").split("\n")


def _find_hooks_block(lines):
    """Locate the top-level `hooks:` block.

    Returns (start, end, present): start..end is the exclusive line range the
    block occupies (trailing blank lines excluded). present is False when no
    top-level `hooks:` key exists."""
    start = None
    inline = False
    for i, line in enumerate(lines):
        m = HOOKS_KEY_RE.match(line)
        if m:
            start = i
            inline = m.group(1).strip() != ""  # value sits on the same line
            break
    if start is None:
        return None, None, False
    if inline:
        return start, start + 1, True
    end = start + 1
    while end < len(lines) and (lines[end].strip() == "" or lines[end][:1] in (" ", "\t")):
        end += 1
    # keep trailing blank separator lines outside the replaced region
    while end > start + 1 and lines[end - 1].strip() == "":
        end -= 1
    return start, end, True


def _parse_hooks_subtree(lines, start, end):
    data = _yaml_load("\n".join(lines[start:end]))
    hooks = data.get("hooks") if _is_map(data) else None
    return hooks if _is_map(hooks) else {}


def _strip_marker(hooks, marker):
    """Drop atrium-owned entries (command contains marker) from every event
    list; drop now-empty event keys."""
    for ev in list(hooks.keys()):
        entries = hooks.get(ev)
        if not isinstance(entries, list):
            continue
        kept = [
            e for e in entries if not (_is_map(e) and marker in str(e.get("command", "")))
        ]
        if kept:
            hooks[ev] = kept
        else:
            del hooks[ev]


def _splice_hooks(cfg_path, transform):
    """Read config.yaml, replace its `hooks:` block with the result of
    transform(existing_hooks_dict), and write back — preserving every byte
    outside the block. Returns nothing; no-op write still keeps the file
    identical."""
    text = open(cfg_path, "r", encoding="utf-8").read() if os.path.exists(cfg_path) else ""
    lines = text.split("\n")  # trailing "" preserves a final newline
    start, end, present = _find_hooks_block(lines)
    existing = _parse_hooks_subtree(lines, start, end) if present else {}
    new_hooks = transform(existing)
    block = _yaml_dump_lines({"hooks": new_hooks})
    if present:
        lines = lines[:start] + block + lines[end:]
    else:
        # No hooks key — insert just before hooks_auto_accept, else append.
        idx = next((i for i, l in enumerate(lines) if AUTO_ACCEPT_RE.match(l)), None)
        if idx is None:
            # append, ensuring a separating newline (drop a single trailing "")
            if lines and lines[-1] == "":
                lines = lines[:-1] + block + [""]
            else:
                lines = lines + block
        else:
            lines = lines[:idx] + block + lines[idx:]
    out = "\n".join(lines)
    d = os.path.dirname(cfg_path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".atrium-cfg.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(out)
        os.replace(tmp, cfg_path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# --------------------------------------------------------------------------
# Consent allowlist
# --------------------------------------------------------------------------

def _load_allowlist(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            data = {}
    except Exception:
        data = {}
    if not isinstance(data.get("approvals"), list):
        data["approvals"] = []
    return data


def _write_allowlist(path, data):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".atrium-allow.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, sort_keys=True)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _drop_marker_approvals(approvals, marker):
    return [
        a
        for a in approvals
        if not (isinstance(a, dict) and marker in str(a.get("command", "")))
    ]


def _seed_allowlist(path, marker, events):
    data = _load_allowlist(path)
    approvals = _drop_marker_approvals(data["approvals"], marker)
    now = _now_iso()
    for spec in events:
        cmd = spec["command"]
        script = cmd.split(" ")[0]
        try:
            mtime = (
                datetime.datetime.fromtimestamp(
                    os.path.getmtime(os.path.expanduser(script)),
                    datetime.timezone.utc,
                )
                .isoformat()
                .replace("+00:00", "Z")
            )
        except OSError:
            mtime = None
        approvals.append(
            {
                "event": spec["event"],
                "command": cmd,
                "approved_at": now,
                "script_mtime_at_approval": mtime,
            }
        )
    data["approvals"] = approvals
    _write_allowlist(path, data)


# --------------------------------------------------------------------------
# Subcommands
# --------------------------------------------------------------------------

def do_install(cfg_path, allow_path, marker, events):
    def transform(existing):
        _strip_marker(existing, marker)
        for spec in events:
            existing.setdefault(spec["event"], []).append(
                {"command": spec["command"], "timeout": int(spec.get("timeout", 10))}
            )
        return existing

    if os.path.exists(cfg_path):
        try:
            import shutil

            shutil.copy2(cfg_path, cfg_path + ".atrium-bak")
        except Exception:
            pass
    _splice_hooks(cfg_path, transform)
    _seed_allowlist(allow_path, marker, events)


def do_uninstall(cfg_path, allow_path, marker):
    if os.path.exists(cfg_path):

        def transform(existing):
            _strip_marker(existing, marker)
            return existing

        _splice_hooks(cfg_path, transform)
    if os.path.exists(allow_path):
        data = _load_allowlist(allow_path)
        data["approvals"] = _drop_marker_approvals(data["approvals"], marker)
        _write_allowlist(allow_path, data)


def do_status(cfg_path, marker):
    installed = False
    activity = False
    if os.path.exists(cfg_path):
        try:
            lines = open(cfg_path, "r", encoding="utf-8").read().split("\n")
            start, end, present = _find_hooks_block(lines)
            hooks = _parse_hooks_subtree(lines, start, end) if present else {}

            def has(ev):
                lst = hooks.get(ev)
                return isinstance(lst, list) and any(
                    _is_map(e) and marker in str(e.get("command", "")) for e in lst
                )

            installed = has("on_session_start")
            activity = any(
                has(e)
                for e in ("pre_tool_call", "post_tool_call", "post_llm_call", "pre_llm_call")
            )
        except Exception:
            pass
    print(
        json.dumps(
            {"subcommand": "status", "installed": installed, "activityHooks": activity}
        )
    )


def main(argv):
    if not argv:
        print('{"error": "missing subcommand"}', file=sys.stderr)
        return 2
    sub = argv[0]
    if sub == "install":
        do_install(argv[1], argv[2], argv[3], json.loads(argv[4]))
    elif sub == "uninstall":
        do_uninstall(argv[1], argv[2], argv[3])
    elif sub == "status":
        do_status(argv[1], argv[2])
    else:
        print(json.dumps({"error": "unknown subcommand: %s" % sub}), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
