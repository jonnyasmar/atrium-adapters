# Native computer use

Use this reference only when the user explicitly supplied the `computer-use:on` composer chip. Invoke every command through `"$ATRIUM_CLI_PATH"` and pass `--json` when reading the output yourself.

## Fast path

Do not begin with `computer status`, `ps`, Quartz scripts, AppleScript, or direct driver calls. They add turns and can bypass atrium's authority model.

```bash
"$ATRIUM_CLI_PATH" computer start --scope auto --json
"$ATRIUM_CLI_PATH" computer apps --json
"$ATRIUM_CLI_PATH" computer attach --pid <exact-running-pid> --json
"$ATRIUM_CLI_PATH" computer observe --pid <pid> --window-id <window-id> --full --json
```

`start` starts and waits for the shared daemon on demand. `apps` is the quick running-app/window inventory. Use `apps --installed` only for cold-launch discovery because scanning installed apps is slower. `attach` authorizes and binds the exact process identity, returns that app's current windows, and prevents PID-reuse attacks. Use `launch --bundle-id …` only when the app is not already running.

Never manufacture a target by writing `computer-use/state.json`. Legacy records without captured process identity fail closed and do not trigger a slow recovery scan.

## Observe, act, batch, verify

`observe` returns a window screenshot, accessibility elements, stable `e:…` refs, and a short lease. Prefer an element ref over labels, and labels over pixel coordinates. Observe again after unrelated UI changes or an expired/consumed lease.

For independent ordered actions, use one batch:

```bash
"$ATRIUM_CLI_PATH" computer batch \
  --pid <pid> --window-id <window-id> \
  --steps '[{"tool":"click","label":"One"},{"tool":"click","label":"Two"}]' \
  --json
```

The fast path resolves all targets from one fresh projection, suppresses per-action recapture, and returns one final screenshot. It halts on a refused, partial, or suspected-no-op result. Use separate observe/action calls when a step creates the target needed by the next step.

Treat `effect`, `evidence`, and `escalation` as authoritative. Use `computer verify --expect '[…]'` for a structured postcondition; do not report success from a click response alone. `computer zoom` provides a precise cropped image when the main screenshot is insufficient.

## Foreground and desktop escalation

Window actions are background by default and do not steal focus. If the driver returns a foreground recommendation, or a fresh observation confirms a background no-op, retry that one action with `--foreground`. atrium asks for approval, serializes it against other foreground/desktop work, and the driver restores the previously frontmost app.

Full-desktop control is available, but never an implicit fallback:

```bash
"$ATRIUM_CLI_PATH" computer start --scope desktop --json
"$ATRIUM_CLI_PATH" computer call get_desktop_state \
  --args '{"screenshot_out_file":"/absolute/path/desktop.png"}' --json
"$ATRIUM_CLI_PATH" computer desktop-action click \
  --args '{"x":420,"y":240}' --json
```

A strict desktop session requires a user grant. An `auto` session can switch permanently to desktop only through `computer call escalate_session --args '{"reason":"…"}'` after the window ladder was actually exhausted. Desktop actions include click, scroll, drag, move-cursor, type-text, press-key, and hotkey. They use screen-absolute coordinates and a global execution lock. End and start a new session to return to window scope.

## Additional driver capabilities

Run `computer tools --json` for the runtime capability registry, then `computer describe <tool> --json` for that primitive's live description and input schema. The registry tells you whether each genuine driver tool is:

- `wrapped`: use atrium's higher-level command because it adds leases, grounding, approvals, privacy handling, or cleanup;
- `direct`: call it through `computer call <tool> --args '{…}'`; atrium injects the session and applies the listed policy;
- `host_only`: intentionally retained by atrium because it changes global configuration or is not safe across concurrent sessions;
- `unsupported`: obsolete or incompatible with the governed surface.

Useful direct groups include native `invoke_menu`; browser prepare/state/navigation/click/type/pointer/dialog/download/file-input operations; cursor position, motion and theme; screen/session/desktop/recording state; health/config/update inspection; and approved app foreground/termination operations. Pass exact `pid` and `window_id` to target/browser calls so atrium can enforce ownership and per-window serialization. Use browser primitives only after `browser_prepare` establishes the driver route.

Recording start/stop and replay are not agent-callable: the current recorder is daemon-global rather than session-scoped, and replay can execute historical input. Configuration, cursor visibility, OS permission prompts, and driver installation also remain host-owned. This is capability fidelity, not a raw bypass: when a safe concurrency or authorization boundary does not exist, the registry says so explicitly.

## Approvals and protected surfaces

In YOLO mode, ordinary app authorization proceeds automatically only for a turn carrying the Computer chip. Clipboard access, persistent configuration, foreground/desktop escalation, and consequential actions retain explicit gates. Clipboard values are never written to the computer-use audit log.

atrium itself is controllable. Terminal/console controls (including embedded terminals), other AI-agent hosts, administrator authentication, and OS security/privacy approval controls remain protected. Never route around a refusal with shell GUI automation or a direct driver invocation.

## Transparency, concurrency, diagnostics, and cleanup

Every session has a visible agent cursor and, when enabled in Settings, a PiP identified with the driving pane title. Window operations lease and lock `(pid, window_id)` independently, so agents can safely drive different windows concurrently. Foreground and desktop operations use one global lock. Session/action metadata and timings are appended to `computer-use/events.jsonl`; clipboard contents and typed values are omitted.

Use `computer status --json` only after a failed start or for diagnostics. It reports installation, daemon, TCC permissions, kill switch, PiP, update, and current session state. `computer stop` immediately revokes input and engages the kill switch; `computer unlock --yes` is an intentional host re-arm.

Always finish a completed run with:

```bash
"$ATRIUM_CLI_PATH" computer end --json
```

That releases targets and leases and closes the PiP. Do not keep the daemon alive manually—atrium owns its shared lifecycle and cleanup.
