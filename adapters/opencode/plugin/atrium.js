// atrium.js — OpenCode plugin that forwards lifecycle events to the
// atrium CLI's `hook emit` interface. Installed by adapters/opencode/hooks.sh
// to ~/.config/opencode/plugins/atrium.js.
//
// OpenCode plugins are TS/JS modules; the plugin system has no JSON-based
// hook configuration. We bridge opencode's native event names to atrium's
// canonical hook event names (`session-start`, `pre-tool-use`, etc.) and
// shell out to `${ATRIUM_CLI_PATH:-atrium} hook emit <event>` with the
// payload on stdin.
//
// Marker line below is what hooks.sh uses to detect a stale install.
// ATRIUM_HOOK_MARKER=atrium-runtime-hook

import { spawn } from "node:child_process";

const ATRIUM_CLI = process.env.ATRIUM_CLI_PATH || "atrium";
const ATRIUM_PANE_ID = process.env.ATRIUM_PANE_ID || "";

// Skip hook emission entirely when not running inside an atrium pane.
// Keeps users who install opencode outside atrium safe from spurious CLI
// invocations on every tool call.
const ATRIUM_ACTIVE = Boolean(process.env.ATRIUM) && Boolean(ATRIUM_PANE_ID);

function emit(event, payload) {
  if (!ATRIUM_ACTIVE) return;
  try {
    const child = spawn(
      ATRIUM_CLI,
      [
        "hook",
        "emit",
        event,
        "--adapter",
        "opencode",
        "--pane-id",
        ATRIUM_PANE_ID,
        "--json",
      ],
      { stdio: ["pipe", "ignore", "ignore"] },
    );
    child.stdin.write(JSON.stringify(payload ?? {}));
    child.stdin.end();
    // Detach: hook fire-and-forget. We never block the agent loop on
    // atrium reachability; the CLI's NFR8 fast-path also exits 0 when
    // the runtime is unreachable.
    child.unref();
  } catch {
    // Swallow — never break the agent on a hook failure.
  }
}

export const AtriumPlugin = async (_ctx) => {
  return {
    // ── Session lifecycle ───────────────────────────────────────────
    "session.created": async (input) => {
      emit("session-start", { session: input?.session });
    },
    "session.idle": async (input) => {
      emit("stop", { session: input?.session });
    },
    "session.deleted": async (input) => {
      // Opencode doesn't fire a clean "session-end"; deletion is the
      // closest analogue. Atrium tolerates either signal.
      emit("session-end", { session: input?.session });
    },

    // ── Tool execution ─────────────────────────────────────────────
    "tool.execute.before": async (input) => {
      emit("pre-tool-use", { tool: input?.tool, args: input?.args });
    },
    "tool.execute.after": async (input) => {
      emit("post-tool-use", {
        tool: input?.tool,
        args: input?.args,
        output: input?.output,
      });
    },

    // ── Permission flow ────────────────────────────────────────────
    "permission.asked": async (input) => {
      emit("permission-request", { permission: input?.permission });
    },

    // ── Prompt submission ──────────────────────────────────────────
    // OpenCode does not expose a clean "user prompt submitted" hook in
    // the plugin API yet; `tui.prompt.append` only fires in TUI mode.
    // Atrium's user-prompt-submit channel stays unwired here until
    // opencode publishes a stable event for it.
  };
};
