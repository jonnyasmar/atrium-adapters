// atrium.ts — pi extension that forwards session, agent, and tool
// lifecycle events to atrium's `hook emit` interface. Installed by
// adapters/pi/hooks.sh to ~/.pi/agent/extensions/atrium.ts.
//
// pi auto-discovers TS extensions in ~/.pi/agent/extensions/ and compiles
// them on the fly via jiti — no build step. Event surface is documented
// at https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md.
//
// Field name remapping (pi-side → atrium-side): every emit translates
// pi's camelCase keys (toolName, toolCallId, input) to atrium's
// snake_case contract (session_id, tool_name, tool_input, tool_response,
// user_prompt, last_assistant_message). Without this remap, atrium's
// activity card shows the agent as a generic terminal pane and renders
// no tool details.
//
// Marker comment below is what hooks.sh uses to detect a stale install.
// ATRIUM_HOOK_MARKER=atrium-runtime-hook

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

const ATRIUM_CLI = process.env.ATRIUM_CLI_PATH || "atrium";
const ATRIUM_PANE_ID = process.env.ATRIUM_PANE_ID || "";
const ATRIUM_ACTIVE = Boolean(process.env.ATRIUM) && Boolean(ATRIUM_PANE_ID);

const DEBUG_LOG =
  process.env.ATRIUM_PI_EXTENSION_LOG || join(tmpdir(), "atrium-pi-extension.log");
const DEBUG = process.env.ATRIUM_PI_EXTENSION_DEBUG !== "0";

function debug(...parts: unknown[]) {
  if (!DEBUG) return;
  try {
    appendFileSync(
      DEBUG_LOG,
      `[${new Date().toISOString()}] [pane=${ATRIUM_PANE_ID || "?"}] ${parts
        .map((p) => (typeof p === "string" ? p : JSON.stringify(p)))
        .join(" ")}\n`,
    );
  } catch {
    // Best-effort logging.
  }
}

debug("atrium pi extension loaded", { ATRIUM_ACTIVE, ATRIUM_CLI, ATRIUM_PANE_ID });

function stringify(value: unknown): string {
  if (value == null) return "";
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function emit(event: string, payload?: Record<string, unknown>) {
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
        "pi",
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

// Run an atrium CLI command and capture its stdout. Unlike emit() (fire-
// and-forget), this awaits the result so a hook can inject the returned
// context into the turn. Fail-open: any error / timeout resolves to ""
// so a slow or unreachable CLI never blocks pi's agent loop.
function runAtriumCapture(
  args: string[],
  stdin?: string,
  timeoutMs = 2500,
): Promise<string> {
  if (!ATRIUM_ACTIVE) return Promise.resolve("");
  return new Promise((resolve) => {
    let out = "";
    let settled = false;
    const finish = (v: string) => {
      if (!settled) {
        settled = true;
        resolve(v);
      }
    };
    try {
      const child = spawn(ATRIUM_CLI, args, {
        stdio: ["pipe", "pipe", "ignore"],
      });
      const timer = setTimeout(() => {
        try {
          child.kill();
        } catch {
          /* already gone */
        }
        finish("");
      }, timeoutMs);
      child.stdout.on("data", (d: Buffer) => {
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

// Extract the injected context string from a resolve-prompt-sigils
// response (claude-shaped hookSpecificOutput envelope). Returns "" for the
// no-op `{}` envelope or any parse failure.
function parseAdditionalContext(raw: string): string {
  if (!raw.trim()) return "";
  try {
    const j = JSON.parse(raw) as {
      hookSpecificOutput?: { additionalContext?: unknown };
    };
    const ctx = j?.hookSpecificOutput?.additionalContext;
    return typeof ctx === "string" ? ctx : "";
  } catch {
    return "";
  }
}

// Generic launcher names atrium nudges the agent to rename away from.
// Mirrors adapters/shared/pane-name-check.sh — pi can't use that shell
// script (it shapes a hook-stdout envelope), so the same check lives here
// and the nudge is injected via before_agent_start.systemPrompt.
const GENERIC_PANE_NAMES = new Set([
  "Pi",
  "Claude Code",
  "Codex",
  "Codex CLI",
  "Gemini",
  "Gemini CLI",
  "Grok",
  "Antigravity",
  "OpenCode",
  "Cursor",
  "Cursor Agent",
  "Terminal",
  "",
]);

const RENAME_NUDGE = `[atrium] This pane is still using its default launcher name. Before responding, rename it to a 10–20 char description of the work:

  $ATRIUM_CLI_PATH pane rename "$ATRIUM_PANE_ID" --name "<new name>"

Front-load scannable bits ("Paste/drop refs", not "Refactoring paste/drop"), describe the work not your role, no status/timestamp/adapter name. If the user has already chosen a name, leave it alone.`;

// Returns the rename nudge when the pane still carries a generic launcher
// name, else "". Silent on any CLI failure.
async function renameNudgeIfGeneric(): Promise<string> {
  const out = await runAtriumCapture([
    "pane",
    "list",
    "--filter",
    `id=${ATRIUM_PANE_ID}`,
    "--json",
  ]);
  if (!out.trim()) return "";
  try {
    const arr = JSON.parse(out) as Array<{ name?: unknown }>;
    const name = Array.isArray(arr) ? arr[0]?.name : undefined;
    if (typeof name === "string" && GENERIC_PANE_NAMES.has(name)) {
      return RENAME_NUDGE;
    }
  } catch {
    /* tolerate */
  }
  return "";
}

// ── Module-level state ──────────────────────────────────────────────
// pi extension modules are loaded once per session and stay alive, so
// we use module-level state for:
// - The current session_id (resolved from ctx.sessionManager).
// - The last assistant message text (captured on message_end, shipped
//   on stop / session_shutdown). pi doesn't surface assistant text in
//   any single hook input; it lives on the `message` object passed to
//   message_end events where role === "assistant".
let sessionId: string | null = null;
let lastAssistantMessage: string | null = null;
// The atrium SessionStart manifest (atrium-context.md + skills) is injected
// once per session as a persistent hidden message; this gates that.
let manifestInjected = false;

// Derive a stable session id from the pi session file path. pi stores
// sessions as `~/.pi/agent/sessions/<cwd-encoded>/<uuid>.jsonl`; the
// basename minus extension is the session uuid. For brand-new ephemeral
// sessions (file not written yet), fall back to the pane id so atrium
// can still create the activity card.
function resolveSessionId(ctx: { sessionManager?: { getSessionFile?: () => string | null } }): string {
  const file = ctx?.sessionManager?.getSessionFile?.();
  if (file && typeof file === "string") {
    return basename(file).replace(/\.jsonl$/i, "");
  }
  return ATRIUM_PANE_ID || "pi-ephemeral";
}

// Extract the text content from a pi Message object. Messages carry
// content as either a string or an array of parts; we concatenate text
// parts and return the result (empty string if none).
function extractMessageText(message: unknown): string {
  if (!message || typeof message !== "object") return "";
  const m = message as { content?: unknown };
  const content = m.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter((p): p is { type?: string; text?: string } => !!p && typeof p === "object")
      .filter((p) => p.type === "text" && typeof p.text === "string")
      .map((p) => p.text as string)
      .join("");
  }
  return "";
}

export default function (pi: ExtensionAPI) {
  // ── Session lifecycle ─────────────────────────────────────────────
  pi.on("session_start", async (event, ctx) => {
    sessionId = resolveSessionId(ctx as { sessionManager?: { getSessionFile?: () => string | null } });
    lastAssistantMessage = null;
    manifestInjected = false;
    emit("session-start", {
      session_id: sessionId,
      reason: (event as { reason?: string })?.reason,
    });
  });

  // session_shutdown fires before the extension runtime tears down.
  // It's the cleanest "session is done" signal. Emit stop + session-end
  // so atrium finalizes the activity card regardless of which signal
  // its reducer listens to.
  pi.on("session_shutdown", async (event) => {
    const reason = (event as { reason?: string })?.reason;
    emit("stop", {
      session_id: sessionId,
      reason,
      last_assistant_message: lastAssistantMessage,
    });
    emit("session-end", { session_id: sessionId, reason });
  });

  // ── Tool lifecycle ────────────────────────────────────────────────
  pi.on("tool_call", async (event) => {
    const e = event as {
      toolName?: string;
      toolCallId?: string;
      input?: unknown;
    };
    emit("pre-tool-use", {
      session_id: sessionId,
      tool_name: e.toolName,
      tool_input: stringify(e.input),
      tool_call_id: e.toolCallId,
    });
  });

  pi.on("tool_result", async (event) => {
    const e = event as {
      toolName?: string;
      toolCallId?: string;
      input?: unknown;
      content?: unknown;
      isError?: boolean;
    };
    emit("post-tool-use", {
      session_id: sessionId,
      tool_name: e.toolName,
      tool_input: stringify(e.input),
      tool_response: stringify(e.content),
      tool_call_id: e.toolCallId,
      error: e.isError ? stringify(e.content) : "",
    });
  });

  // ── User prompt ───────────────────────────────────────────────────
  // input fires when the user submits a prompt. event.text is the raw
  // input text (before skill/template expansion).
  pi.on("input", async (event) => {
    const e = event as { text?: string; source?: string };
    // Reset assistant-message buffer so the previous turn's reply
    // doesn't bleed into this turn's stop event.
    lastAssistantMessage = null;
    emit("user-prompt-submit", {
      session_id: sessionId,
      user_prompt: e.text ?? "",
      source: e.source,
    });
  });

  // ── Context injection ────────────────────────────────────────────
  // before_agent_start fires after the user submits a prompt, before the
  // agent loop, and (unlike pi.on emit handlers) its return value is
  // consumed: `message` injects a persistent message, `systemPrompt`
  // replaces the turn's system prompt (chained across extensions). This
  // is pi's same-turn context-injection primitive — the equivalent of
  // Claude's UserPromptSubmit additionalContext. We use it to deliver the
  // three things atrium injects for first-class adapters:
  //   1. the SessionStart manifest (atrium-context.md + skills) — once,
  //      as a persistent hidden message,
  //   2. resolved `+name` sigil bodies for this prompt,
  //   3. the pane-rename nudge while the pane name is still generic.
  // All fetches are fail-open (empty string on any error) so a slow or
  // unreachable atrium CLI never blocks pi's turn.
  pi.on("before_agent_start", async (event) => {
    if (!ATRIUM_ACTIVE) return undefined;
    const e = event as { prompt?: string; systemPrompt?: string };
    const result: {
      message?: { customType: string; content: string; display: boolean };
      systemPrompt?: string;
    } = {};

    if (!manifestInjected) {
      manifestInjected = true;
      const manifest = await runAtriumCapture([
        "skills",
        "resolve-manifest",
        "--pane-id",
        ATRIUM_PANE_ID,
        "--adapter",
        "pi",
      ]);
      if (manifest.trim()) {
        result.message = {
          customType: "atrium-context",
          content: manifest,
          display: false,
        };
      }
    }

    const additions: string[] = [];

    const sigilOut = await runAtriumCapture(
      [
        "skills",
        "resolve-prompt-sigils",
        "--pane-id",
        ATRIUM_PANE_ID,
        "--adapter",
        "pi",
      ],
      JSON.stringify({ prompt: e.prompt ?? "" }),
    );
    const sigilCtx = parseAdditionalContext(sigilOut);
    if (sigilCtx) additions.push(sigilCtx);

    const nudge = await renameNudgeIfGeneric();
    if (nudge) additions.push(nudge);

    if (additions.length > 0) {
      result.systemPrompt = `${e.systemPrompt ?? ""}\n\n${additions.join("\n\n")}`;
    }

    debug("before_agent_start inject", {
      manifest: result.message != null,
      sigils: sigilCtx.length > 0,
      nudge: nudge.length > 0,
    });
    return Object.keys(result).length > 0 ? result : undefined;
  });

  // ── Assistant message capture ────────────────────────────────────
  // message_end fires for user / assistant / toolResult messages.
  // Capture text from assistant messages so we can attach it as
  // last_assistant_message on the next stop event.
  pi.on("message_end", async (event) => {
    const e = event as { message?: { role?: string; content?: unknown } };
    if (e.message?.role !== "assistant") return;
    const text = extractMessageText(e.message);
    if (text) lastAssistantMessage = text;
  });

  // ── Turn boundary ────────────────────────────────────────────────
  // agent_end fires when the agent finishes a turn. atrium uses `stop`
  // for "turn complete" transitions.
  pi.on("agent_end", async () => {
    emit("stop", {
      session_id: sessionId,
      reason: "agent_end",
      last_assistant_message: lastAssistantMessage,
    });
  });
}
