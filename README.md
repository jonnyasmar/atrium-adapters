# Atrium Adapter SDK

This is the adapter registry and SDK for [Atrium](https://github.com/jonnyasmar/atrium). Adapters are shell-script plugins that teach Atrium how to detect, launch, resume, and manage AI coding tools. Each adapter is a self-contained directory: one JSON manifest and up to nine bash scripts. No compiled code, no runtime dependencies beyond `jq` and standard POSIX utilities.

---

## Quick Start: Build Your First Adapter

Create a working adapter for a hypothetical tool called `mytool`. Every file below is copy-pasteable.

### 1. Create the directory and manifest

```bash
mkdir -p ~/.atrium/adapters/mytool && cd ~/.atrium/adapters/mytool
```

Create `adapter.json`:

```json
{
  "sdkVersion": 2,
  "name": "mytool",
  "displayName": "My Tool",
  "description": "My AI coding assistant",
  "accent": "#3b82f6",
  "binary": "mytool",
  "version": "1.0.0",
  "binaryDiscovery": {
    "commands": ["mytool"],
    "wellKnownPaths": [
      "/usr/local/bin/mytool",
      "/opt/homebrew/bin/mytool",
      "~/.local/bin/mytool"
    ]
  },
  "methods": {
    "build_launch_command": { "script": "build_launch_command.sh" },
    "build_resume_command": { "script": "build_resume_command.sh" },
    "list_recent_sessions": { "script": "list_recent_sessions.sh" },
    "hooks":                { "script": "hooks.sh" },
    "launcher_options":     { "static": "launcher_options.json" }
  }
}
```

### 2. Implement the minimum scripts

**`build_launch_command.sh`** -- starts a session:

```bash
#!/usr/bin/env bash
set -euo pipefail
echo '{"command": ["mytool"]}'
```

### 3. Stub the rest, validate, launch

Create minimal stubs for the other methods (see [Method Reference](#method-reference)), then:

```bash
chmod +x *.sh
./validate-adapter.sh ~/.atrium/adapters/mytool/
```

Restart Atrium. Your adapter appears in the launcher if the binary is found.

---

## Adapter Structure

SDK v2 (the current shape — see the adapters in `adapters/` for canonical examples):

```
mytool/
  adapter.json                # Manifest (required)
  build_launch_command.sh     # Builds command to start a new session
  build_resume_command.sh     # Builds command to resume a session
  list_recent_sessions.sh     # Lists recent sessions for a working directory
  hooks.sh                    # Manages hook install/uninstall/status
  launcher_options.json       # Static JSON for launcher UI toggles
```

The manifest alone plus `build_launch_command.sh` is the minimum for a functional adapter; the rest are optional. Binary detection moved to the manifest's `binaryDiscovery` field in v2 (atrium walks `commands` on `PATH`, falls back to `wellKnownPaths`).

SDK v1 shipped additional scripts (`detect_binary.sh`, `detect_running.sh`, `extract_session_id.sh`, `check_auth.sh`). They are still accepted by the validator for legacy community adapters but no longer required — atrium's runtime drives the same behavior from the v2 manifest fields.

### Script Conventions

- Start with `#!/usr/bin/env bash` and `set -euo pipefail`
- Output exactly one JSON object to stdout; diagnostics go to stderr only
- Complete within 3 seconds (`list_recent_sessions`: 50ms)
- Must be executable (`chmod +x`)
- Runs without your shell profile; stdin is `/dev/null`

---

## Manifest Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sdkVersion` | integer | Yes | SDK version. `2` is current; `1` is still accepted for legacy adapters. |
| `name` | string | Yes | Machine identifier. Pattern: `^[a-z0-9-]+$` |
| `displayName` | string | Yes | Human-readable name for the UI |
| `description` | string | Yes | Short description |
| `accent` | string | Yes | Hex color (`#RRGGBB`) for UI theming |
| `binary` | string | Yes | CLI binary name (e.g. `claude`, `codex`) |
| `version` | string | Yes | Semver version of this adapter |
| `author` | string | No | Author name |
| `methods` | object | Yes | Map of method names to `{"script": "file.sh"}` or `{"static": "file.json"}` |
| `binaryDiscovery` | object | No (v2) | `{commands: [...], wellKnownPaths: [...]}` — replaces v1 `detect_binary.sh`. atrium walks `commands` on `PATH`, then the fallback paths. |
| `hooks` | object | No (v2) | Map of kebab-case event name → stable `atrium://` URI (e.g. `"session-start": "atrium://hooks/mytool/session-start"`). atrium exposes resolved URIs to `hooks.sh install` via `ATRIUM_HOOK_URI_*` env vars. |
| `skillInstallPath` | string | No (v2) | Absolute or `~`-prefixed path where atrium installs the adapter's `SKILL.md` (e.g. `~/.claude/skills/atrium/skill.md`). |

---

## Method Reference

### Environment Variables

Set before every script execution:

| Variable | Description | Example |
|----------|-------------|---------|
| `ATRIUM_ADAPTER_DIR` | Absolute path to this adapter's directory | `~/.atrium/adapters/mytool` |
| `ATRIUM_DATA_DIR` | Absolute path to Atrium's data directory | `~/.atrium` |
| `ATRIUM_HOOK_PORT` | Port of the local hook HTTP server | `17322` |
| `ATRIUM_SDK_VERSION` | SDK version the host app supports | `2` |

### Exit Codes

| Code | Meaning | Behavior |
|------|---------|----------|
| `0` | Success | Output parsed as JSON |
| `1` | Graceful failure | Treated as "not found" / "not available" |
| `2+` | Error | Logged to `~/.atrium/logs/` |

Prefer exit 0 with a null/empty JSON result over exit 1.

---

### detect_binary

Locates the tool's CLI binary.

**Args:** None | **Output:** `{"path": "/usr/local/bin/mytool"}` or `{"path": null}` | **Exit:** Always 0

---

### detect_running

Checks if the tool is running in a pane's process tree.

**Args:** `$1` = shell PID | **Output:** `{"running": true}` or `{"running": false}` | **Exit:** Always 0

Walk child processes of the given PID with `pgrep -P` and match on the binary name.

---

### extract_session_id

Extracts the active session ID from a running tool's process arguments.

**Args:** `$1` = shell PID | **Output:** `{"sessionId": "abc-123", "args": null}` or `{"sessionId": null}` | **Exit:** Always 0

The `args` field is reserved; set it to `null`.

---

### list_recent_sessions

Lists recent sessions for a working directory, sorted by `lastActive` descending.

**Args:** `$1` = working directory (absolute path) | **Exit:** Always 0 (empty array if none)

**Output:** `{"sessions": [{"id": "abc", "name": "Fix auth bug", "cwd": "/path", "lastActive": "2025-06-15T10:30:00Z"}]}`

Each session: `id` (string), `name` (string or null), `cwd` (string), `lastActive` (ISO 8601 string).

**Performance:** Called per visible pane. Must complete in under 50ms. Use batch operations (`stat` + `sort` + `jq -s`), never per-file subprocess loops.

---

### build_launch_command

Builds the command array to start a new session.

**Args:** `$1` = flags JSON | **Output:** `{"command": ["mytool", "--flag"]}` | **Exit:** 0 = success, 1 = cannot build

Flags JSON keys: `dangerouslySkipPermissions` (boolean), `worktreePath` (string or null), `extra` (object -- adapter-specific flags from launcher_options).

---

### build_resume_command

Builds the command array to resume an existing session.

**Args:** `$1` = session ID, `$2` = flags JSON | **Output:** `{"command": ["mytool", "--resume", "id"]}` | **Exit:** 0 = success, 1 = cannot build

---

### check_auth

Checks whether the tool is authenticated.

**Args:** None | **Exit:** Always 0

**Output:** `{"authenticated": true}` or `{"authenticated": false, "message": "Run mytool auth to log in.", "command": "mytool auth login"}`

When `false`: `message` is shown in the UI, `command` is the CLI command to authenticate.

---

### hooks

Manages hook lifecycle for session awareness.

**Args:** `$1` = subcommand (`install`, `uninstall`, or `status`)

| Subcommand | Output | Exit |
|------------|--------|------|
| `install` | `{"subcommand": "install", "installed": true}` | 0 or 1 |
| `uninstall` | `{"subcommand": "uninstall", "uninstalled": true}` | 0 or 1 |
| `status` | `{"subcommand": "status", "installed": true/false}` | 0 |

Exit 2 for unknown subcommands. See [Hook Integration](#hook-integration) for implementation details.

---

### launcher_options

A static JSON file (not a script) defining toggle options in the launcher bar.

```json
{
  "options": [{
    "key": "dangerouslySkipPermissions",
    "label": "Skip Permissions",
    "description": "Skip permission prompts (use with caution)",
    "type": "toggle",
    "default": false
  }]
}
```

Option `key` values map directly to the flags JSON passed to `build_launch_command` and `build_resume_command`.

---

## Hook Integration

Hooks let Atrium track session starts and ends inside an AI tool, powering pane header status and session tracking.

### How It Works

1. Atrium runs a local HTTP server; port is written to `~/.atrium/hook-port`
2. `hooks.sh install` writes tool-specific config that POSTs to this server
3. When sessions start/end, the tool fires requests to Atrium

### Endpoints

```
POST http://127.0.0.1:{port}/api/adapter/{adapter-name}/session-start
POST http://127.0.0.1:{port}/api/adapter/{adapter-name}/session-end
```

Content-Type: `application/json`. Payload is whatever the tool passes via stdin.

### Hook Command Template

Reads the port at execution time (survives Atrium restarts):

```bash
PORT=$(cat ~/.atrium/hook-port 2>/dev/null) && [ -n "$PORT" ] && \
  curl -s -X POST http://127.0.0.1:$PORT/api/adapter/mytool/session-start \
  -H 'Content-Type: application/json' -d "$(cat)"
```

### Per-Tool Examples

**Claude Code** -- `hooks.sh` deep-merges entries into `~/.claude/settings.json` under `hooks.SessionStart` and `hooks.SessionEnd`, preserving non-Atrium hooks. Uninstall removes only Atrium entries. Atomic writes via temp file + `mv`.

**Codex** -- requires `codex_hooks = true` in `~/.codex/config.toml` plus hook definitions in `~/.codex/hooks.json` following the same `SessionStart`/`SessionEnd` structure.

### Writing Your Own

1. Identify how your tool supports hooks (config file, env var, plugin API)
2. Build a hook command that reads `~/.atrium/hook-port` and POSTs to the endpoint
3. `hooks.sh install` -- write hook config into tool's configuration
4. `hooks.sh uninstall` -- remove only Atrium's hooks
5. `hooks.sh status` -- report whether hooks are installed
6. Use atomic writes to avoid corrupting config files

---

## Testing and Validation

```bash
./validate-adapter.sh ~/.atrium/adapters/mytool/
```

Checks performed:
- `adapter.json` exists and conforms to the manifest schema
- All referenced scripts exist and are executable
- Each script produces valid JSON with synthetic inputs
- Output matches the method's JSON schema
- Scripts complete within timeout

Clone this repo and run `./validate-adapter.sh adapters/claude-code/` for a reference run. CI validates automatically on every pull request.

---

## Publishing

1. Fork this repository
2. Add your adapter directory under `adapters/yourname/`
3. Run `./validate-adapter.sh adapters/yourname/`
4. Add your entry to `registry.json`:

```json
{
  "name": "yourname",
  "displayName": "Your Tool",
  "description": "Short description",
  "accent": "#hexcolor",
  "binary": "yourtool",
  "sdkVersion": 2,
  "platforms": ["macos"],
  "official": false,
  "version": "1.0.0",
  "minAppVersion": "1.0.0"
}
```

5. Open a pull request -- CI validates automatically

**Guidelines:** Self-contained, no deps beyond `jq` + POSIX. Bash, tested on macOS and Ubuntu. 3s timeout (50ms for `list_recent_sessions`). Atomic writes for config files. Never store credentials.

---

## Available Adapters

| Name | Description | Binary | Status |
|------|-------------|--------|--------|
| [claude-code](adapters/claude-code/) | Anthropic's AI coding assistant | `claude` | Official |
| [codex](adapters/codex/) | OpenAI's AI coding assistant | `codex` | Official |
| [gemini](adapters/gemini/) | Google's AI coding assistant | `gemini` | Official |
| [cursor-agent](adapters/cursor-agent/) | Cursor's agent CLI | `cursor-agent` | Community |

---

Source-of-truth JSON schemas for the manifest and all method outputs live in `schemas/`. See [LICENSE](LICENSE) for license details.
