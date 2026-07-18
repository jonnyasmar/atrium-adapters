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
import { appendFileSync, readFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const ATRIUM_CLI = process.env.ATRIUM_CLI_PATH || "atrium";
const ATRIUM_PANE_ID = process.env.ATRIUM_PANE_ID || "";
const ATRIUM_ACTIVE = Boolean(process.env.ATRIUM) && Boolean(ATRIUM_PANE_ID);
const ATRIUM_DATA_DIR = process.env.ATRIUM_DATA_DIR || join(homedir(), ".atrium");
const CHAT_SDK_HOOKS = Boolean(process.env.ATRIUM_CHAT_SDK_HOOKS);

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

// Run an atrium CLI command and capture its stdout (vs. emit()'s fire-
// and-forget). Used by the system-prompt transform to fetch context to
// inject. Fail-open: any error / timeout resolves to "" so a slow or
// unreachable CLI never blocks opencode's request.
function runAtriumCapture(args, stdin, timeoutMs = 2500) {
  if (!ATRIUM_ACTIVE) return Promise.resolve("");
  return new Promise((resolve) => {
    let out = "";
    let settled = false;
    const finish = (v) => {
      if (!settled) {
        settled = true;
        resolve(v);
      }
    };
    try {
      const child = spawn(ATRIUM_CLI, args, { stdio: ["pipe", "pipe", "ignore"] });
      const timer = setTimeout(() => {
        try {
          child.kill();
        } catch {
          /* already gone */
        }
        finish("");
      }, timeoutMs);
      child.stdout.on("data", (d) => {
        out += d.toString();
      });
      child.on("close", () => {
        clearTimeout(timer);
        finish(out);
      });
      child.on("error", () => {
        clearTimeout(timer);
        finish("");
      });
      if (stdin != null) child.stdin.write(stdin);
      child.stdin.end();
    } catch {
      finish("");
    }
  });
}

// Fetch the pipeline context (Epic 77/78) from the hook server's
// context_injection route for a given injectable event. atrium's context
// providers assemble an envelope that rides the `atriumContext` field of the
// /api/adapter/opencode/<event> JSON response (the same contract claude-code
// uses via inject-context.sh). opencode delivers it by pushing the string onto
// the system prompt in chat.system.transform (its only same-turn injection
// primitive — it runs on every provider request, including the tool-loop
// continuation after a tool runs, so PostToolUse context rides the next
// transform). `event` is the kebab-case event path (session-start |
// user-prompt-submit | post-tool-use). Fail-open: any error / timeout /
// missing port resolves to "" so a slow or unreachable hook server never blocks
// opencode's request.
async function fetchPipelineContext(event, sessionID, model, timeoutMs = 2000) {
  if (!ATRIUM_ACTIVE) return "";
  try {
    // Hook server port is written by the running app, per data dir.
    let port = "";
    try {
      port = readFileSync(join(ATRIUM_DATA_DIR, "hook-port"), "utf8").trim();
    } catch {
      return ""; // no port file ⇒ no running server ⇒ nothing to inject
    }
    if (!port) return "";

    // Native-ish payload mirroring what the corresponding hook would carry.
    const payload = JSON.stringify({
      session_id: sessionID ?? null,
      model: model ?? null,
    });

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let res;
    try {
      res = await fetch(`http://127.0.0.1:${port}/api/adapter/opencode/${event}`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Atrium-Pane-Id": ATRIUM_PANE_ID,
        },
        body: payload,
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timer);
    }
    if (!res || !res.ok) return "";
    const data = await res.json();
    const ctx = data?.atriumContext;
    return typeof ctx === "string" ? ctx : "";
  } catch {
    return "";
  }
}

// Extract the injected context string from a resolve-prompt-sigils response
// (claude-shaped hookSpecificOutput envelope); "" for the no-op `{}` envelope.
function parseAdditionalContext(raw) {
  if (!raw.trim()) return "";
  try {
    const j = JSON.parse(raw);
    const ctx = j?.hookSpecificOutput?.additionalContext;
    return typeof ctx === "string" ? ctx : "";
  } catch {
    return "";
  }
}

// The SessionStart manifest (atrium-context.md + skills) is session-stable,
// so fetch it once and reuse across requests rather than re-shelling out
// on every system-prompt build.
let manifestCache = null;
// Latest user prompt awaiting `+name` sigil resolution. Captured in
// chat.message (which carries the prompt text) and consumed by the next
// system.transform (which has no prompt of its own), then cleared so
// tool-loop continuation requests don't re-resolve a stale prompt.
let pendingSigilPrompt = null;
// Epic 78 Story 78.3 — pipeline atriumContext delivery for the new injectable
// events. opencode's only same-turn injection primitive is system.transform,
// which runs on every provider request; we gate the per-event pipeline fetch on
// a flag set by the lifecycle handler that fired, then clear it so a tool-loop
// continuation doesn't re-inject. UserPromptSubmit ⇐ chat.message;
// PostToolUse ⇐ tool.execute.after (its context rides the NEXT transform, the
// continuation request after the tool runs).
let pendingUserPromptInject = false;
let pendingPostToolInject = false;

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
      // Hand the prompt to the next system.transform for sigil resolution.
      if (userText) pendingSigilPrompt = userText;
      // Mark the UserPromptSubmit pipeline atriumContext for the next transform.
      pendingUserPromptInject = true;
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
      // Mark the PostToolUse pipeline atriumContext for the NEXT transform —
      // the tool-loop continuation request after this tool runs (system.transform
      // is opencode's only inject point; there's no return-based after-tool hook).
      pendingPostToolInject = true;
    },

    // ── Permission flow.
    "permission.ask": async (input, _output) => {
      emit("permission-request", { session_id: lastSessionId, permission: input });
    },

    // ── Context injection. opencode has no return-based prompt hook, but
    // the system prompt is assembled through this transform: pushing onto
    // output.system adds system-prompt segments for the request. This is
    // opencode's same-turn injection primitive — the equivalent of Claude's
    // UserPromptSubmit additionalContext / pi's before_agent_start, and it
    // runs on every provider request (including tool-loop continuations). We
    // use it to deliver the atrium SessionStart manifest (atrium-context.md +
    // skills, telling the agent it runs inside atrium and how to drive it),
    // the Epic 77 run-command pipeline context (atriumContext from the hook
    // server, this adapter's SessionStart-equivalent delivery), the Epic 78
    // Story 78.3 pipeline atriumContext for UserPromptSubmit (after a user
    // message) and PostToolUse (on the continuation after a tool runs), and the
    // resolved `+name` sigil bodies. Every fetch is fail-open.
    "experimental.chat.system.transform": async (input, output) => {
      if (CHAT_SDK_HOOKS || !ATRIUM_ACTIVE || !output || !Array.isArray(output.system)) return;
      if (manifestCache == null) {
        const m = await runAtriumCapture([
          "skills",
          "resolve-manifest",
          "--pane-id",
          ATRIUM_PANE_ID,
          "--adapter",
          "opencode",
        ]);
        if (m.trim()) manifestCache = m;
      }
      if (manifestCache) output.system.push(manifestCache);
      // SessionStart run-command pipeline context (atriumContext) from the hook
      // server. Re-fetched per request (it's session/run-state dependent, unlike
      // the session-stable manifest); fail-open skips the push on any error.
      const runCtx = await fetchPipelineContext("session-start", input?.sessionID, input?.model);
      if (runCtx) output.system.push(runCtx);
      // UserPromptSubmit pipeline atriumContext — fetched once per user message
      // (flag set in chat.message), then cleared so tool-loop continuations
      // don't re-inject. Fail-open.
      let upsCtx = "";
      if (pendingUserPromptInject) {
        pendingUserPromptInject = false;
        upsCtx = await fetchPipelineContext("user-prompt-submit", input?.sessionID, input?.model);
        if (upsCtx) output.system.push(upsCtx);
      }
      // PostToolUse pipeline atriumContext — fetched on the continuation request
      // after a tool runs (flag set in tool.execute.after), then cleared.
      // Fail-open.
      let postCtx = "";
      if (pendingPostToolInject) {
        pendingPostToolInject = false;
        postCtx = await fetchPipelineContext("post-tool-use", input?.sessionID, input?.model);
        if (postCtx) output.system.push(postCtx);
      }
      // Per-prompt `+name` sigil bodies — resolve once per user message
      // (the prompt was captured in chat.message), then clear so tool-loop
      // continuation requests don't re-inject a stale prompt's sigils.
      let sigilCtx = "";
      if (pendingSigilPrompt != null) {
        const p = pendingSigilPrompt;
        pendingSigilPrompt = null;
        const sigilOut = await runAtriumCapture(
          ["skills", "resolve-prompt-sigils", "--pane-id", ATRIUM_PANE_ID, "--adapter", "opencode"],
          JSON.stringify({ prompt: p }),
        );
        sigilCtx = parseAdditionalContext(sigilOut);
        if (sigilCtx) output.system.push(sigilCtx);
      }
      debug("system.transform inject", {
        manifest: Boolean(manifestCache),
        runCommand: runCtx.length > 0,
        userPromptSubmit: upsCtx.length > 0,
        postToolUse: postCtx.length > 0,
        sigils: sigilCtx.length > 0,
      });
    },
  };
};

// Some loaders prefer a default export. Provide it as an alias.
export default AtriumPlugin;
