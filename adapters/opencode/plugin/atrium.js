// atrium.js — OpenCode plugin that forwards lifecycle events to the
// atrium CLI's `hook emit` interface. Installed by adapters/opencode/hooks.sh
// to ~/.config/opencode/plugins/atrium.js.
//
// Built against @opencode-ai/plugin's `Hooks` interface (v1.4.x). Plugin
// auto-discovers from ~/.config/opencode/plugins/ (global) and
// ./.opencode/plugins/ (project). Both named (`export const AtriumPlugin`)
// and default exports are provided so we cover any loader convention.
//
// Marker line below is what hooks.sh uses to detect a stale install.
// ATRIUM_HOOK_MARKER=atrium-runtime-hook

import { spawn } from "node:child_process";
import { appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ATRIUM_CLI = process.env.ATRIUM_CLI_PATH || "atrium";
const ATRIUM_PANE_ID = process.env.ATRIUM_PANE_ID || "";
const ATRIUM_ACTIVE = Boolean(process.env.ATRIUM) && Boolean(ATRIUM_PANE_ID);

// Debug log path. Set ATRIUM_PLUGIN_DEBUG=0 to silence. Useful while
// validating that opencode actually loads the plugin and what events it
// surfaces — we found in the wild that several event names guessed from
// docs were wrong, so visibility here pays for itself.
const DEBUG_LOG = process.env.ATRIUM_PLUGIN_LOG || join(tmpdir(), "atrium-opencode-plugin.log");
const DEBUG = process.env.ATRIUM_PLUGIN_DEBUG !== "0";

function debug(...parts) {
  if (!DEBUG) return;
  try {
    appendFileSync(
      DEBUG_LOG,
      `[${new Date().toISOString()}] [pane=${ATRIUM_PANE_ID || "?"}] ${parts
        .map((p) => (typeof p === "string" ? p : JSON.stringify(p)))
        .join(" ")}\n`,
    );
  } catch {
    // Logging is best-effort.
  }
}

debug("atrium plugin loaded", { ATRIUM_ACTIVE, ATRIUM_CLI, ATRIUM_PANE_ID });

function emit(event, payload) {
  debug("emit", event, payload ?? {});
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
    child.unref();
  } catch (err) {
    debug("emit failed", String(err));
  }
}

export const AtriumPlugin = async (_input, _options) => {
  debug("AtriumPlugin factory invoked");
  return {
    // ── Catch-all event bus. opencode emits session.created /
    // session.idle / session.deleted / session.error / permission.asked
    // / permission.replied through this channel (see Event union in
    // @opencode-ai/sdk). The named hooks below (tool.execute.*,
    // chat.message, permission.ask) cover everything else.
    event: async ({ event }) => {
      const t = event?.type;
      debug("event", t);
      switch (t) {
        case "session.created":
          emit("session-start", { event });
          break;
        case "session.idle":
          emit("stop", { event });
          break;
        case "session.deleted":
          emit("session-end", { event });
          break;
        case "session.error":
          emit("stop", { event, error: true });
          break;
      }
    },

    // ── Per-turn signal: user sent a new chat message.
    "chat.message": async (input, _output) => {
      emit("user-prompt-submit", { sessionID: input?.sessionID, agent: input?.agent });
    },

    // ── Tool lifecycle. opencode's hook signature is (input, output)
    // where the BEFORE hook may mutate output.args, and the AFTER hook
    // receives input.args plus the executed output.
    "tool.execute.before": async (input, output) => {
      emit("pre-tool-use", {
        tool: input?.tool,
        sessionID: input?.sessionID,
        callID: input?.callID,
        args: output?.args,
      });
    },
    "tool.execute.after": async (input, output) => {
      emit("post-tool-use", {
        tool: input?.tool,
        sessionID: input?.sessionID,
        callID: input?.callID,
        args: input?.args,
        output: output?.output,
        title: output?.title,
      });
    },

    // ── Permission flow. `permission.ask` is the named hook (the
    // `permission.asked` Event type comes through the catch-all `event`
    // bus and would duplicate this — keep one path of record).
    "permission.ask": async (input, _output) => {
      emit("permission-request", { permission: input });
    },
  };
};

// Some loaders prefer a default export. Provide it as an alias so the
// plugin loads under either convention.
export default AtriumPlugin;
