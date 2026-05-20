// atrium.js — OpenCode plugin that forwards lifecycle events to the
// atrium CLI's `hook emit` interface. Installed by adapters/opencode/hooks.sh
// to ~/.config/opencode/plugins/atrium.js and registered in
// ~/.config/opencode/opencode.jsonc under the `plugin` array (opencode
// does NOT auto-discover from plugins/ in practice — explicit
// registration is required).
//
// Field name remapping (opencode-side → atrium-side): every emit
// translates opencode's camelCase keys (sessionID, tool, args) to
// atrium's snake_case contract (session_id, tool_name, tool_input).
// Without this remap, atrium's activity card shows no tool details.
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
    // Best-effort.
  }
}

debug("atrium plugin loaded", { ATRIUM_ACTIVE, ATRIUM_CLI, ATRIUM_PANE_ID });

function stringify(value) {
  if (value == null) return "";
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

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

// Module-level state: remember the most recent assistant message text so
// we can attach it to the `stop` event. opencode doesn't deliver it in
// any hook input — it streams through the catch-all `event` bus across
// two event types with a timing gotcha:
//
//   message.part.updated  carries part.type="text" + part.text + part.messageID
//                         (the accumulated final string) — but NO role.
//   message.updated       carries properties.info.id + properties.info.role
//                         — but NO text.
//
// And empirically message.part.updated arrives BEFORE message.updated
// for the same messageID, so we can't gate text capture on "is this
// assistant?" at part-update time. Solution: index text by messageID as
// it streams in, and promote to lastAssistantMessage when message.updated
// later confirms the role.
let lastAssistantMessage = null;
let lastSessionId = null;
const messageTexts = new Map(); // messageID → latest text

function maybeCaptureAssistantText(event) {
  if (!event || typeof event !== "object") return;
  const t = event.type;
  const props = event.properties;
  if (!props) return;

  if (t === "message.part.updated") {
    const part = props.part;
    if (
      part?.type === "text" &&
      typeof part.text === "string" &&
      part.text.length > 0 &&
      part.messageID
    ) {
      messageTexts.set(part.messageID, part.text);
    }
    return;
  }

  if (t === "message.updated") {
    const info = props.info;
    if (info?.id && info?.role === "assistant") {
      const text = messageTexts.get(info.id);
      if (text) lastAssistantMessage = text;
    }
  }
}

export const AtriumPlugin = async (_input, _options) => {
  debug("AtriumPlugin factory invoked");
  return {
    // ── Catch-all event bus. opencode emits session.created /
    // session.idle / session.deleted / session.error / message.updated /
    // permission.asked through this channel (see Event union in
    // @opencode-ai/sdk). We use it for session-lifecycle bridging AND
    // for assistant-message capture (no hook input exposes assistant
    // text directly).
    event: async ({ event }) => {
      const t = event?.type;
      debug("event", t);
      // Dump message.* event shapes once per type so we can see what
      // fields actually carry the assistant text.
      if (t && t.startsWith("message.")) {
        debug("event-payload", t, event);
      }
      maybeCaptureAssistantText(event);
      switch (t) {
        case "session.created": {
          const sid = event.properties?.info?.id ?? event.properties?.session?.id ?? null;
          if (sid) lastSessionId = sid;
          emit("session-start", { session_id: lastSessionId });
          break;
        }
        case "session.idle": {
          const sid = event.properties?.sessionID ?? lastSessionId;
          emit("stop", {
            session_id: sid,
            last_assistant_message: lastAssistantMessage,
          });
          // Reset for the next turn. Keep messageTexts intact so it
          // doesn't get GC'd mid-stream of the next reply.
          lastAssistantMessage = null;
          break;
        }
        case "session.deleted":
          emit("session-end", { session_id: lastSessionId });
          break;
        case "session.error":
          emit("stop", { session_id: lastSessionId, error: true });
          break;
      }
    },

    // ── Per-turn signal: user sent a new chat message. Maps to atrium
    // user-prompt-submit. Translate sessionID → session_id and lift the
    // prompt text from the output message parts.
    "chat.message": async (input, output) => {
      if (input?.sessionID) lastSessionId = input.sessionID;
      const userText = (output?.parts ?? [])
        .filter((p) => p?.type === "text" && typeof p.text === "string")
        .map((p) => p.text)
        .join("");
      emit("user-prompt-submit", {
        session_id: input?.sessionID,
        user_prompt: userText || null,
      });
    },

    // ── Tool lifecycle. opencode's hook signature is (input, output)
    // where the BEFORE hook may mutate output.args, and the AFTER hook
    // receives input.args plus the executed output. We translate to
    // atrium's tool_name + tool_input (+ tool_response on after).
    "tool.execute.before": async (input, output) => {
      if (input?.sessionID) lastSessionId = input.sessionID;
      emit("pre-tool-use", {
        session_id: input?.sessionID,
        tool_name: input?.tool,
        tool_input: stringify(output?.args),
      });
    },
    "tool.execute.after": async (input, output) => {
      if (input?.sessionID) lastSessionId = input.sessionID;
      emit("post-tool-use", {
        session_id: input?.sessionID,
        tool_name: input?.tool,
        tool_input: stringify(input?.args),
        tool_response: stringify(output?.output),
      });
    },

    // ── Permission flow.
    "permission.ask": async (input, _output) => {
      emit("permission-request", { session_id: lastSessionId, permission: input });
    },
  };
};

// Some loaders prefer a default export. Provide it as an alias.
export default AtriumPlugin;
