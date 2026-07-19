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
import { appendFileSync, readFileSync } from "node:fs";
import { request } from "node:http";
import { homedir, tmpdir } from "node:os";
import { basename, join } from "node:path";

const ATRIUM_CLI = process.env.ATRIUM_CLI_PATH || "atrium";
const ATRIUM_PANE_ID = process.env.ATRIUM_PANE_ID || "";
const ATRIUM_ACTIVE = Boolean(process.env.ATRIUM) && Boolean(ATRIUM_PANE_ID);
const CHAT_SDK_HOOKS = Boolean(process.env.ATRIUM_CHAT_SDK_HOOKS);
const INPUT_REQUEST_TOOLS_ENV = "ATRIUM_INPUT_REQUEST_TOOLS_PI";
const DEFAULT_INPUT_REQUEST_TOOLS: string[] = [];

const DEBUG_LOG =
  process.env.ATRIUM_PI_EXTENSION_LOG ||
  join(tmpdir(), "atrium-pi-extension.log");
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

function inputRequestTools(): ReadonlySet<string> {
  const raw = process.env[INPUT_REQUEST_TOOLS_ENV];
  if (raw == null) return new Set(DEFAULT_INPUT_REQUEST_TOOLS);
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return new Set(DEFAULT_INPUT_REQUEST_TOOLS);
    return new Set(
      parsed
        .filter((tool): tool is string => typeof tool === "string")
        .map((tool) => tool.trim())
        .filter(Boolean),
    );
  } catch {
    return new Set(DEFAULT_INPUT_REQUEST_TOOLS);
  }
}

const INPUT_REQUEST_TOOLS = inputRequestTools();

debug("atrium pi extension loaded", {
  ATRIUM_ACTIVE,
  ATRIUM_CLI,
  ATRIUM_PANE_ID,
});

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
  // Chat-sidecar sessions get activity from the chat runtime's turn bridge —
  // engine-side lifecycle emits double-feed the activity card and (with no
  // settling stop behind them) wedge it in "working".
  if (CHAT_SDK_HOOKS) return;
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

// Fetch the pipeline context (Epic 77/78) from the hook server's HTTP route for
// a given injectable event. atrium's context providers (RunCommandStatusProvider,
// …) run in the hook server's context_injection pipeline and the assembled
// envelope rides the `atriumContext` field on POST /api/adapter/pi/<event>. pi
// has no shell hook, so this is pi's delivery: read the hook-port (written per
// data-dir by the running app), POST the pane id on the X-Atrium-Pane-Id header,
// and read `.atriumContext`. `event` is the kebab-case event path (session-start
// | user-prompt-submit | post-tool-use). Fail-open: any error / timeout / no
// port resolves to "" so a slow or unreachable hook server never blocks the turn.
function fetchPipelineContext(
  event: string,
  timeoutMs = 2000,
): Promise<string> {
  if (!ATRIUM_ACTIVE) return Promise.resolve("");

  const dataDir = process.env.ATRIUM_DATA_DIR || join(homedir(), ".atrium");
  let port = "";
  try {
    port = readFileSync(join(dataDir, "hook-port"), "utf8").trim();
  } catch {
    return Promise.resolve("");
  }
  if (!port) return Promise.resolve("");

  return new Promise((resolve) => {
    let settled = false;
    const finish = (v: string) => {
      if (!settled) {
        settled = true;
        resolve(v);
      }
    };
    try {
      const req = request(
        {
          host: "127.0.0.1",
          port: Number(port),
          path: `/api/adapter/pi/${event}`,
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Atrium-Pane-Id": ATRIUM_PANE_ID,
          },
          timeout: timeoutMs,
        },
        (res) => {
          if (res.statusCode == null || res.statusCode >= 400) {
            res.resume();
            finish("");
            return;
          }
          let body = "";
          res.setEncoding("utf8");
          res.on("data", (chunk: string) => {
            body += chunk;
          });
          res.on("end", () => {
            try {
              const j = JSON.parse(body) as { atriumContext?: unknown };
              finish(
                typeof j.atriumContext === "string" ? j.atriumContext : "",
              );
            } catch {
              finish("");
            }
          });
        },
      );
      req.on("timeout", () => {
        req.destroy();
        finish("");
      });
      req.on("error", () => finish(""));
      // SessionStart hooks carry no native body; an empty JSON object keeps the
      // route's payload parse happy.
      req.end("{}");
    } catch {
      finish("");
    }
  });
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
let pendingPermissionPrompt: PermissionUiPromptEvent | null = null;
// The atrium SessionStart context (manifest + run-command pipeline context) is
// injected once per session as a persistent hidden message; this gates that.
let manifestInjected = false;

type PiSessionManager = {
  getSessionId?: () => string | null;
  getSessionFile?: () => string | null;
};

type PermissionUiPromptEvent = {
  requestId?: string;
  source?: string;
  surface?: string | null;
  value?: string | null;
  message?: string;
  agentName?: string | null;
};

type PermissionDecisionEvent = {
  surface?: string;
  value?: string;
  result?: "allow" | "deny";
  resolution?: string;
  agentName?: string | null;
};

function resolveSessionId(ctx: { sessionManager?: PiSessionManager }): string {
  const id = ctx?.sessionManager?.getSessionId?.();
  if (id && typeof id === "string") return id;

  const file = ctx?.sessionManager?.getSessionFile?.();
  if (file && typeof file === "string") {
    const stem = basename(file).replace(/\.jsonl$/i, "");
    return (
      stem.match(
        /(?:^|_)([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$/i,
      )?.[1] ?? stem
    );
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
      .filter(
        (p): p is { type?: string; text?: string } =>
          !!p && typeof p === "object",
      )
      .filter((p) => p.type === "text" && typeof p.text === "string")
      .map((p) => p.text as string)
      .join("");
  }
  return "";
}

export default function (pi: ExtensionAPI) {
  const unsubscribePermissionPrompt = pi.events.on(
    "permissions:ui_prompt",
    (raw) => {
      if (!raw || typeof raw !== "object") return;
      const event = raw as PermissionUiPromptEvent;
      if (typeof event.requestId !== "string") return;

      pendingPermissionPrompt = event;
      emit("permission-request", {
        session_id: sessionId,
        tool_name: event.surface ?? "permission",
        tool_input: event.message ?? event.value ?? "Permission required",
        request_kind: "permission",
        permission_request_id: event.requestId,
        permission_source: event.source,
        agent_name: event.agentName,
      });
    },
  );

  const unsubscribePermissionDecision = pi.events.on(
    "permissions:decision",
    (raw) => {
      if (!pendingPermissionPrompt || !raw || typeof raw !== "object") return;
      const event = raw as PermissionDecisionEvent;
      if (
        typeof event.resolution !== "string" ||
        !event.resolution.startsWith("user_")
      ) {
        return;
      }

      emit("permission-response", {
        session_id: sessionId,
        tool_name:
          event.surface ?? pendingPermissionPrompt.surface ?? "permission",
        tool_input:
          pendingPermissionPrompt.message ??
          event.value ??
          pendingPermissionPrompt.value ??
          "Permission resolved",
        request_kind: "permission",
        permission_request_id: pendingPermissionPrompt.requestId,
        permission_result: event.result,
        permission_resolution: event.resolution,
        agent_name: event.agentName ?? pendingPermissionPrompt.agentName,
      });
      pendingPermissionPrompt = null;
    },
  );

  // ── Session lifecycle ─────────────────────────────────────────────
  pi.on("session_start", async (event, ctx) => {
    sessionId = resolveSessionId(ctx as { sessionManager?: PiSessionManager });
    lastAssistantMessage = null;
    pendingPermissionPrompt = null;
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
    pendingPermissionPrompt = null;
    unsubscribePermissionPrompt();
    unsubscribePermissionDecision();
  });

  // ── Tool lifecycle ────────────────────────────────────────────────
  pi.on("tool_call", async (event) => {
    const e = event as {
      toolName?: string;
      toolCallId?: string;
      input?: unknown;
    };
    const payload = {
      session_id: sessionId,
      tool_name: e.toolName,
      tool_input: stringify(e.input),
      tool_call_id: e.toolCallId,
    };
    if (e.toolName && INPUT_REQUEST_TOOLS.has(e.toolName)) {
      emit("permission-request", { ...payload, request_kind: "question" });
      return;
    }
    emit("pre-tool-use", payload);
  });

  // tool_result fires after a tool executes, before the LLM receives the
  // result, and (unlike emit-only handlers) its return value CAN modify the
  // result: returning `{ content }` extends the content blocks the model sees
  // (handlers chain like middleware). This is pi's PostToolUse injection point
  // (Epic 78 Story 78.3) — the matrix's named capable event, carrying the tool
  // RESULT. We fetch the pipeline atriumContext for post-tool-use and append it
  // as a trailing text block so a post-action provider's context reaches the
  // model right after the tool output. Fail-open: skip the append on any error.
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
    if (!ATRIUM_ACTIVE) return undefined;
    const postCtx = await fetchPipelineContext("post-tool-use");
    if (!postCtx.trim()) return undefined;
    // Append-only: preserve the existing content blocks, add atrium's context
    // as a trailing text block. `content` is the chained result so far.
    const existing = Array.isArray(e.content) ? e.content : [];
    debug("tool_result inject", { postToolUse: true });
    return { content: [...existing, { type: "text", text: postCtx }] };
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
  // things atrium injects for first-class adapters:
  //   1. the SessionStart manifest (atrium-context.md + skills) plus the
  //      SessionStart run-command pipeline context (Epic 77) — once, combined
  //      into one persistent hidden message,
  //   2. the UserPromptSubmit pipeline atriumContext (Epic 78 Story 78.3) —
  //      fetched per turn (this hook IS pi's UserPromptSubmit-equivalent),
  //   3. resolved `+name` sigil bodies for this prompt.
  // (PostToolUse pipeline context is delivered separately, on the tool_result
  // hook.) All fetches are fail-open (empty string on any error) so a slow or
  // unreachable atrium CLI never blocks pi's turn.
  pi.on("before_agent_start", async (event) => {
    if (!ATRIUM_ACTIVE || CHAT_SDK_HOOKS) return undefined;
    const e = event as { prompt?: string; systemPrompt?: string };
    const result: {
      message?: { customType: string; content: string; display: boolean };
      systemPrompt?: string;
    } = {};

    if (!manifestInjected) {
      manifestInjected = true;
      // Both the SessionStart manifest and the SessionStart run-command pipeline
      // context (Epic 77) are SessionStart-equivalent, so fetch them together and
      // deliver them through the one persistent hidden message. Concurrent —
      // independent fail-open fetches.
      const [manifest, pipelineContext] = await Promise.all([
        runAtriumCapture([
          "skills",
          "resolve-manifest",
          "--pane-id",
          ATRIUM_PANE_ID,
          "--adapter",
          "pi",
        ]),
        fetchPipelineContext("session-start"),
      ]);
      const sessionStartParts = [manifest, pipelineContext]
        .map((p) => p.trim())
        .filter(Boolean);
      if (sessionStartParts.length > 0) {
        result.message = {
          customType: "atrium-context",
          content: sessionStartParts.join("\n\n"),
          display: false,
        };
      }
    }

    const additions: string[] = [];

    // UserPromptSubmit pipeline atriumContext — fetched every turn (this hook is
    // pi's UserPromptSubmit-equivalent). Fail-open skips it on any error.
    const upsCtx = await fetchPipelineContext("user-prompt-submit");
    if (upsCtx.trim()) additions.push(upsCtx);

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

    if (additions.length > 0) {
      result.systemPrompt = `${e.systemPrompt ?? ""}\n\n${additions.join("\n\n")}`;
    }

    debug("before_agent_start inject", {
      manifest: result.message != null,
      userPromptSubmit: upsCtx.trim().length > 0,
      sigils: sigilCtx.length > 0,
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
