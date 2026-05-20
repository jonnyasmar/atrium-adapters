// atrium.ts — pi extension that forwards session, agent, and tool
// lifecycle events to atrium's `hook emit` interface. Installed by
// adapters/pi/hooks.sh to ~/.pi/agent/extensions/atrium.ts.
//
// pi auto-discovers TS extensions in ~/.pi/agent/extensions/ and compiles
// them on the fly via jiti — no build step. Event surface is documented
// at https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md.
//
// Marker comment below is what hooks.sh uses to detect a stale install.
// ATRIUM_HOOK_MARKER=atrium-runtime-hook

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ATRIUM_CLI = process.env.ATRIUM_CLI_PATH || "atrium";
const ATRIUM_PANE_ID = process.env.ATRIUM_PANE_ID || "";
const ATRIUM_ACTIVE = Boolean(process.env.ATRIUM) && Boolean(ATRIUM_PANE_ID);

// Debug log path for verifying load + event flow. Disable with
// ATRIUM_PI_EXTENSION_DEBUG=0.
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

export default function (pi: ExtensionAPI) {
  // ── Session lifecycle ─────────────────────────────────────────────
  // session_start fires with reason "startup" | "reload" | "new" |
  // "resume" | "fork". atrium treats all of those as session-start.
  pi.on("session_start", async (event) => {
    emit("session-start", { reason: (event as { reason?: string })?.reason });
  });

  // session_shutdown fires before the extension runtime tears down.
  // Reason "quit" is the true session end; everything else is a
  // soft-reset that pi will follow with another session_start. We emit
  // both stop and session-end so atrium's activity card finalizes
  // regardless of which transition the user is in.
  pi.on("session_shutdown", async (event) => {
    const reason = (event as { reason?: string })?.reason;
    emit("stop", { reason });
    emit("session-end", { reason });
  });

  // ── Tool lifecycle ────────────────────────────────────────────────
  // tool_call fires before the LLM-requested tool runs. We can return
  // `{block, reason}` to gate it; atrium hooks deliberately do not gate
  // (the user's permission UI keeps full control).
  pi.on("tool_call", async (event) => {
    const e = event as { toolName?: string; toolCallId?: string; input?: unknown };
    emit("pre-tool-use", {
      tool: e.toolName,
      callID: e.toolCallId,
      input: e.input,
    });
  });

  // tool_result fires after a tool finishes (success or error).
  pi.on("tool_result", async (event) => {
    const e = event as {
      toolName?: string;
      toolCallId?: string;
      input?: unknown;
      output?: unknown;
      error?: unknown;
    };
    emit("post-tool-use", {
      tool: e.toolName,
      callID: e.toolCallId,
      input: e.input,
      output: e.output,
      error: e.error,
    });
  });

  // ── User prompt ───────────────────────────────────────────────────
  // input fires when the user submits a prompt (and lets extensions
  // intercept it). We don't modify; just forward as user-prompt-submit.
  pi.on("input", async (event) => {
    const e = event as { input?: unknown; source?: string };
    emit("user-prompt-submit", { source: e.source, input: e.input });
  });

  // ── Turn boundary ─────────────────────────────────────────────────
  // agent_end fires when the agent finishes a turn. atrium uses `stop`
  // for "turn complete" transitions in the activity card; session
  // tear-down also emits stop above, but multiple stops are idempotent.
  pi.on("agent_end", async () => {
    emit("stop", { reason: "agent_end" });
  });
}
