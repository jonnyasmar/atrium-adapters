// Loads one plugin adapter's real module and fires its pre-tool hook once.
//
//   node tests/plugin-command-guard-runner.mjs <opencode|pi|omp> <tool> <command>
//
// The environment (ATRIUM, ATRIUM_PANE_ID, ATRIUM_CLI_PATH, …) is the caller's,
// since the modules read it at import. Prints one JSON line:
//   {"outcome":"refused","reason":"…"} | {"outcome":"allowed"}
import { pathToFileURL } from "node:url";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const [adapter, tool, command] = process.argv.slice(2);
const root = join(dirname(fileURLToPath(import.meta.url)), "..", "adapters");

async function fire() {
  if (adapter === "opencode") {
    const plugin = await import(pathToFileURL(join(root, "opencode/plugin/atrium.js")).href);
    const hooks = await plugin.AtriumPlugin({}, {});
    try {
      await hooks["tool.execute.before"]({ tool, sessionID: "s" }, { args: { command } });
    } catch (error) {
      return { outcome: "refused", reason: String(error?.message ?? error) };
    }
    return { outcome: "allowed" };
  }
  const extension = await import(pathToFileURL(join(root, adapter, "extension/atrium.ts")).href);
  const handlers = {};
  extension.default({
    on: (event, handler) => (handlers[event] = handler),
    // pi's event bus (permission prompts); the guard path doesn't use it.
    events: { on: () => () => {} },
  });
  const result = await handlers.tool_call({ toolName: tool, toolCallId: "c", input: { command } }, {});
  return result?.block ? { outcome: "refused", reason: result.reason } : { outcome: "allowed" };
}

console.log(JSON.stringify(await fire()));
