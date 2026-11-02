#!/usr/bin/env node
// The HQ library atrium's directors start from: curated personas, routines
// and staff templates, one markdown file each under hq/library/<kind>s/,
// compiled into hq/library.json. atrium compiles a snapshot of that file in
// and refreshes it from this repo's main, so a push here reaches every client
// within the hour, with no app release.
//
// Usage:
//   node scripts/build-hq-library.mjs           # write hq/library.json
//   node scripts/build-hq-library.mjs --check   # exit 1 if it's stale or a check fails
//
// A bundle file is YAML frontmatter, then its long text as sections:
// `## Instructions` and `## Playbook` (personas), `## Instructions` (staff),
// `## Prompt` (routines). Inside `## Playbook` the playbook's own sections sit
// one level down (`### How I work`); they are lifted to `##` here.
//
// The frontmatter is a strict YAML subset (block maps and sequences, flow
// maps and sequences, plain and quoted scalars, `#` comments): this repo has
// no package dependencies, and anything outside the subset is an error, not
// a guess. The JSON schema (schemas/hq-library.schema.json) is checked by
// check-schemas.py; the rules a schema can't express are checked here.

import { existsSync, readFileSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const sourceDir = join(root, "hq", "library");
const outPath = join(root, "hq", "library.json");
const catalogPath = join(root, "connectors", "catalog.json");

const KINDS = [
  ["personas", "persona"],
  ["routines", "routine"],
  ["staff", "staff"],
];
const BUILT_IN_SLOTS = new Set(["director", "timezone"]);
const ASK_FIRST_EFFECTS = new Set(["send", "post", "buy", "delete"]);
const PLAYBOOK_SECTIONS = ["How I work", "Checklists", "Lessons", "Defaults"];
const PLAYBOOK_ITEM_CHARS = 200;
const PLAYBOOK_CHARS = 3000;
const BUNDLE_BYTES = 16 * 1024;
const PERSONA_SHARE_BYTES = 64 * 1024;
const MIN_GAP_MINUTES = 15;
const MAX_FIRES_PER_DAY = 48;
// NUL, zero-width characters, line and paragraph separators, bidi controls
// and the BOM: invisible in review, so never in content. Code points, not
// escapes, so this file itself can't carry one by accident.
const HIDDEN_RANGES = [
  [0x0000, 0x0000],
  [0x200b, 0x200f],
  [0x2028, 0x202e],
  [0x2060, 0x2064],
  [0x2066, 0x2069],
  [0xfeff, 0xfeff],
];
const SLOT = /\{([a-z][a-z0-9_]*)\}/g;

// Key order in the compiled document, so a diff reads the way the files do.
const ORDER = [
  "kind",
  "id",
  "revision",
  "title",
  "summary",
  "category",
  "tags",
  "icon",
  "description",
  "hello",
  "routines",
  "staff",
  "look",
  "labels",
  "brain",
  "target",
  "mode",
  "schedule",
  "scheduleLabel",
  "doneWhen",
  "runOptions",
  "params",
  "needs",
  "effects",
  "asksFirst",
  "minAtrium",
  "attribution",
  "instructions",
  "playbook",
  "prompt",
];

function hasHidden(text) {
  for (const ch of text) {
    const code = ch.codePointAt(0);
    if (HIDDEN_RANGES.some(([lo, hi]) => code >= lo && code <= hi)) return true;
  }
  return false;
}

class YamlError extends Error {}

// ---------- the YAML subset ----------

// A quote opens a quoted scalar only where a scalar starts: at the start of
// the text, or after whitespace or one of `[ { , :`. Elsewhere (`you'd`) it's
// an ordinary character.
function opensQuote(text, i) {
  if (text[i] !== '"' && text[i] !== "'") return false;
  let j = i - 1;
  while (j >= 0 && text[j] === " ") j--;
  return j < 0 || "[{,:-".includes(text[j]) || j < i - 1;
}

function stripComment(line) {
  let quote = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quote) {
      if (c === "\\" && quote === '"') i++;
      else if (c === quote) quote = null;
    } else if (opensQuote(line, i)) {
      quote = c;
    } else if (c === "#" && (i === 0 || /\s/.test(line[i - 1]))) {
      return line.slice(0, i).trimEnd();
    }
  }
  return line.trimEnd();
}

function indentOf(line) {
  if (line.startsWith("\t")) throw new YamlError("tabs are not allowed for indentation");
  return /^( *)/.exec(line)[1].length;
}

function plainScalar(text) {
  const t = text.trim();
  if (t === "" || t === "~" || t === "null") return null;
  if (t === "true") return true;
  if (t === "false") return false;
  if (/^-?\d+$/.test(t)) return Number(t);
  if (/^-?\d+\.\d+$/.test(t)) return Number(t);
  if (/^[&*!|>%@`]/.test(t)) throw new YamlError(`unsupported YAML in "${t}"`);
  return t;
}

function skipSpace(text, pos) {
  while (pos < text.length && /\s/.test(text[pos])) pos++;
  return pos;
}

// A flow value (or a scalar) from `text` at `pos`; returns [value, nextPos].
function parseFlow(text, pos, inFlow) {
  pos = skipSpace(text, pos);
  const c = text[pos];
  if (c === "[") {
    const out = [];
    pos = skipSpace(text, pos + 1);
    if (text[pos] === "]") return [out, pos + 1];
    for (;;) {
      let value;
      [value, pos] = parseFlow(text, pos, true);
      out.push(value);
      pos = skipSpace(text, pos);
      if (text[pos] === ",") {
        pos = skipSpace(text, pos + 1);
        if (text[pos] === "]") return [out, pos + 1];
        continue;
      }
      if (text[pos] === "]") return [out, pos + 1];
      throw new YamlError(`expected , or ] at "${text.slice(pos, pos + 20)}"`);
    }
  }
  if (c === "{") {
    const out = {};
    pos = skipSpace(text, pos + 1);
    if (text[pos] === "}") return [out, pos + 1];
    for (;;) {
      let key;
      [key, pos] = parseKey(text, pos);
      if (Object.hasOwn(out, key)) throw new YamlError(`duplicate key "${key}"`);
      let value;
      [value, pos] = parseFlow(text, pos, true);
      out[key] = value;
      pos = skipSpace(text, pos);
      if (text[pos] === ",") {
        pos = skipSpace(text, pos + 1);
        if (text[pos] === "}") return [out, pos + 1];
        continue;
      }
      if (text[pos] === "}") return [out, pos + 1];
      throw new YamlError(`expected , or } at "${text.slice(pos, pos + 20)}"`);
    }
  }
  if (c === '"') return parseDoubleQuoted(text, pos);
  if (c === "'") return parseSingleQuoted(text, pos);
  let end = pos;
  if (inFlow) {
    while (end < text.length && !",]}".includes(text[end])) end++;
  } else {
    end = text.length;
  }
  return [plainScalar(text.slice(pos, end)), end];
}

function parseKey(text, pos) {
  let key;
  let end;
  if (text[pos] === '"') [key, end] = parseDoubleQuoted(text, pos);
  else if (text[pos] === "'") [key, end] = parseSingleQuoted(text, pos);
  else {
    end = pos;
    while (end < text.length && text[end] !== ":" && !",]}".includes(text[end])) end++;
    key = text.slice(pos, end).trim();
  }
  if (text[end] !== ":") throw new YamlError(`expected "key:" at "${text.slice(pos, pos + 20)}"`);
  if (!key) throw new YamlError("empty key");
  return [String(key), end + 1];
}

function parseDoubleQuoted(text, pos) {
  let end = pos + 1;
  while (end < text.length && text[end] !== '"') {
    if (text[end] === "\\") end++;
    end++;
  }
  if (end >= text.length) throw new YamlError("unterminated double-quoted string");
  return [JSON.parse(text.slice(pos, end + 1)), end + 1];
}

function parseSingleQuoted(text, pos) {
  let out = "";
  let end = pos + 1;
  for (;;) {
    if (end >= text.length) throw new YamlError("unterminated single-quoted string");
    if (text[end] === "'") {
      if (text[end + 1] === "'") {
        out += "'";
        end += 2;
        continue;
      }
      return [out, end + 1];
    }
    out += text[end];
    end++;
  }
}

function bracketDepth(text) {
  let depth = 0;
  let quote = null;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote) {
      if (c === "\\" && quote === '"') i++;
      else if (c === quote) quote = null;
    } else if (opensQuote(text, i)) quote = c;
    else if (c === "[" || c === "{") depth++;
    else if (c === "]" || c === "}") depth--;
  }
  return depth;
}

// A value written after `key:` or `- `: a flow collection may run on over
// following lines until its brackets close.
function inlineValue(first, lines, state) {
  let text = first;
  if (/^[[{]/.test(text.trim())) {
    while (bracketDepth(text) > 0) {
      if (state.i >= lines.length) throw new YamlError("unclosed flow collection");
      text += ` ${lines[state.i].text.trim()}`;
      state.i++;
    }
  }
  const [value, end] = parseFlow(text, 0, false);
  if (text.slice(end).trim()) throw new YamlError(`trailing text "${text.slice(end).trim()}"`);
  return value;
}

function startsSequence(line, indent) {
  const body = line.text.slice(indent);
  return body === "-" || body.startsWith("- ");
}

function parseBlock(lines, state, indent) {
  if (startsSequence(lines[state.i], indent)) return parseSequence(lines, state, indent);
  return parseMapping(lines, state, indent);
}

function withLine(line, parse) {
  try {
    return parse();
  } catch (error) {
    if (error instanceof YamlError && !error.message.startsWith("line ")) {
      throw new YamlError(`line ${line.no}: ${error.message}`);
    }
    throw error;
  }
}

function parseMapping(lines, state, indent) {
  const out = {};
  while (state.i < lines.length) {
    const line = lines[state.i];
    if (line.indent < indent) break;
    if (line.indent > indent) throw new YamlError(`line ${line.no}: unexpected indentation`);
    if (startsSequence(line, indent)) break;
    const body = line.text.slice(indent);
    const [key, after] = withLine(line, () => parseKey(body, 0));
    const rest = body.slice(after);
    if (Object.hasOwn(out, key)) throw new YamlError(`line ${line.no}: duplicate key "${key}"`);
    state.i++;
    const next = lines[state.i];
    if (rest.trim()) {
      out[key] = withLine(line, () => inlineValue(rest, lines, state));
    } else if (next && next.indent > indent) {
      out[key] = parseBlock(lines, state, next.indent);
    } else if (next && next.indent === indent && startsSequence(next, indent)) {
      out[key] = parseSequence(lines, state, indent);
    } else {
      out[key] = null;
    }
  }
  return out;
}

function parseSequence(lines, state, indent) {
  const out = [];
  while (state.i < lines.length) {
    const line = lines[state.i];
    if (line.indent !== indent || !startsSequence(line, indent)) break;
    const item = line.text.slice(indent + 1).trim();
    const itemIndent = indent + 2;
    if (!item) {
      state.i++;
      const next = lines[state.i];
      if (!next || next.indent <= indent) throw new YamlError(`line ${line.no}: empty sequence item`);
      out.push(parseBlock(lines, state, next.indent));
      continue;
    }
    if (!/^[[{"']/.test(item) && /^[^:]+:(\s|$)/.test(item)) {
      // `- key: value` starts a block mapping whose keys align after the dash.
      lines[state.i] = { ...line, indent: itemIndent, text: " ".repeat(itemIndent) + item };
      out.push(parseMapping(lines, state, itemIndent));
      continue;
    }
    state.i++;
    out.push(withLine(line, () => inlineValue(item, lines, state)));
  }
  return out;
}

export function parseYaml(text) {
  const lines = [];
  text.split("\n").forEach((raw, index) => {
    const stripped = stripComment(raw);
    if (!stripped.trim()) return;
    lines.push({ no: index + 1, text: stripped, indent: indentOf(stripped) });
  });
  if (!lines.length) return {};
  const state = { i: 0 };
  const value = parseBlock(lines, state, lines[0].indent);
  if (state.i < lines.length) throw new YamlError(`line ${lines[state.i].no}: unexpected content`);
  return value;
}

// ---------- bundle files ----------

function splitFile(text, file) {
  const match = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/.exec(text.replace(/\r\n/g, "\n"));
  if (!match) throw new Error(`${file}: expected YAML frontmatter between --- lines`);
  const sections = {};
  let current = null;
  for (const line of match[2].split("\n")) {
    const heading = /^## (.+?)\s*$/.exec(line);
    if (heading) {
      current = heading[1];
      if (Object.hasOwn(sections, current)) throw new Error(`${file}: "## ${current}" appears twice`);
      sections[current] = [];
      continue;
    }
    if (current === null) {
      if (line.trim()) throw new Error(`${file}: text before the first ## section`);
      continue;
    }
    sections[current].push(line);
  }
  const bodies = {};
  for (const [name, body] of Object.entries(sections)) bodies[name] = body.join("\n").trim();
  return { frontmatter: match[1], sections: bodies };
}

// `### How I work` becomes `## How I work`, and `#### …` becomes `### …`.
function liftPlaybook(text) {
  return text
    .split("\n")
    .map((line) => (/^#{3,4} /.test(line) ? line.slice(1) : line))
    .join("\n");
}

function omit(object, keys) {
  return Object.fromEntries(Object.entries(object).filter(([key]) => !keys.includes(key)));
}

// The connectors lane's single-preset shorthand, `{preset, why, required}`,
// as the full form every client reads.
function normaliseNeed(need) {
  if (need && typeof need === "object" && !Array.isArray(need) && "preset" in need && !("anyOf" in need)) {
    const rest = omit(need, ["preset", "id", "why", "required"]);
    return { id: need.id ?? need.preset, why: need.why, required: need.required, anyOf: [{ preset: need.preset }], ...rest };
  }
  return need;
}

function ordered(bundle) {
  const out = {};
  for (const key of ORDER) if (bundle[key] !== undefined) out[key] = bundle[key];
  for (const key of Object.keys(bundle)) if (!(key in out)) out[key] = bundle[key];
  return out;
}

const SECTIONS_BY_KIND = {
  persona: ["Instructions", "Playbook"],
  routine: ["Prompt"],
  staff: ["Instructions"],
};

function compileFile(path, dirKind) {
  const rel = path.slice(root.length + 1);
  const { frontmatter, sections } = splitFile(readFileSync(path, "utf8"), rel);
  let fm;
  try {
    fm = parseYaml(frontmatter);
  } catch (error) {
    throw new Error(`${rel}: frontmatter: ${error.message}`);
  }
  const expected = SECTIONS_BY_KIND[dirKind];
  for (const name of Object.keys(sections)) {
    if (!expected.includes(name)) {
      throw new Error(`${rel}: unexpected section "## ${name}" (a ${dirKind} has ${expected.map((n) => `## ${n}`).join(", ")})`);
    }
  }
  for (const name of expected) {
    if (!sections[name]) throw new Error(`${rel}: missing "## ${name}"`);
  }
  const bundle = { tags: [], params: [], needs: [], asksFirst: [], ...fm };
  if (sections.Instructions) bundle.instructions = sections.Instructions;
  if (sections.Playbook) bundle.playbook = liftPlaybook(sections.Playbook);
  if (sections.Prompt) bundle.prompt = sections.Prompt;
  if (Array.isArray(bundle.needs)) bundle.needs = bundle.needs.map(normaliseNeed);
  return { rel, dirKind, bundle: ordered(bundle) };
}

export function compileLibrary() {
  const files = [];
  for (const [dir, kind] of KINDS) {
    const path = join(sourceDir, dir);
    if (!existsSync(path)) continue;
    for (const name of readdirSync(path).sort()) {
      if (name.endsWith(".md")) files.push(compileFile(join(path, name), kind));
    }
  }
  return files;
}

// ---------- checks a schema can't express ----------

function slotsIn(text) {
  return [...String(text ?? "").matchAll(SLOT)].map((m) => m[1]);
}

function bundleTexts(bundle) {
  return [
    bundle.title,
    bundle.summary,
    bundle.description,
    bundle.instructions,
    bundle.playbook,
    bundle.prompt,
    bundle.hello?.greeting,
    bundle.scheduleLabel,
    bundle.doneWhen,
  ].filter((t) => typeof t === "string");
}

function expandCronField(field, min, max) {
  const out = new Set();
  for (const part of field.split(",")) {
    const [range, stepText] = part.split("/");
    const step = stepText === undefined ? 1 : Number(stepText);
    let lo;
    let hi;
    if (range === "*") [lo, hi] = [min, max];
    else if (range.includes("-")) [lo, hi] = range.split("-").map(Number);
    else [lo, hi] = [Number(range), stepText === undefined ? Number(range) : max];
    if (![lo, hi, step].every(Number.isInteger) || lo < min || hi > max || lo > hi || step < 1) return null;
    for (let v = lo; v <= hi; v += step) out.add(v);
  }
  return [...out].sort((a, b) => a - b);
}

// The guards the daemon enforces on a routine that wakes a chat: at least 15
// minutes between fires and at most 48 a day.
function scheduleErrors(cron) {
  const fields = cron.trim().split(/\s+/);
  if (fields.length !== 5) return [`cron "${cron}" needs five fields`];
  const minutes = expandCronField(fields[0], 0, 59);
  const hours = expandCronField(fields[1], 0, 23);
  const rest = [
    expandCronField(fields[2], 1, 31),
    expandCronField(fields[3], 1, 12),
    expandCronField(fields[4], 0, 7),
  ];
  if (!minutes || !hours || rest.some((r) => !r)) return [`cron "${cron}" isn't one this check can read`];
  const fires = hours.flatMap((h) => minutes.map((m) => h * 60 + m)).sort((a, b) => a - b);
  const errors = [];
  if (fires.length > MAX_FIRES_PER_DAY) {
    errors.push(`fires ${fires.length} times a day; a director routine fires at most ${MAX_FIRES_PER_DAY}`);
  }
  if (fires.length > 1) {
    let gap = Infinity;
    for (let i = 0; i < fires.length; i++) {
      const next = i + 1 < fires.length ? fires[i + 1] : fires[0] + 24 * 60;
      gap = Math.min(gap, next - fires[i]);
    }
    if (gap < MIN_GAP_MINUTES) errors.push(`fires ${gap} minutes apart; a director routine waits at least ${MIN_GAP_MINUTES}`);
  }
  return errors;
}

function playbookErrors(playbook) {
  const errors = [];
  if (playbook.length > PLAYBOOK_CHARS) errors.push(`playbook is ${playbook.length} characters; at most ${PLAYBOOK_CHARS}`);
  const headings = [...playbook.matchAll(/^## (.+)$/gm)].map((m) => m[1]);
  const order = headings.map((h) => PLAYBOOK_SECTIONS.indexOf(h));
  if (order.some((i) => i < 0)) {
    errors.push(`playbook sections are ${PLAYBOOK_SECTIONS.join(", ")}; found ${headings.join(", ")}`);
  } else if (order.some((i, k) => k > 0 && i <= order[k - 1])) {
    errors.push(`playbook sections are out of order: ${headings.join(", ")}`);
  }
  for (const line of playbook.split("\n")) {
    if (line.startsWith("- ") && line.length - 2 > PLAYBOOK_ITEM_CHARS) {
      errors.push(`playbook item over ${PLAYBOOK_ITEM_CHARS} characters (${line.length - 2}): "${line.slice(2, 60)}…"`);
    }
  }
  return errors;
}

function checkNeeds(bundle, presets, fail) {
  const effects = new Set(bundle.effects ?? []);
  const ids = new Set();
  for (const need of bundle.needs ?? []) {
    if (ids.has(need.id)) fail(`names the need "${need.id}" twice`);
    ids.add(need.id);
    for (const alt of need.anyOf ?? []) {
      if (alt.preset && !presets.has(alt.preset)) {
        fail(`need "${need.id}" names preset "${alt.preset}", which connectors/catalog.json doesn't have`);
      }
    }
    if (!need.autonomy) continue;
    if (!(need.anyOf ?? []).some((alt) => alt.preset)) {
      fail(`need "${need.id}" asks for autonomy, which only a connector preset can be given`);
    }
    for (const effect of need.autonomy.for ?? []) {
      if (!effects.has(effect)) fail(`need "${need.id}" asks for autonomy to ${effect}, which the bundle doesn't declare`);
      if (ASK_FIRST_EFFECTS.has(effect)) fail(`need "${need.id}" asks for autonomy to ${effect}, which always asks first`);
    }
  }
  if ([...effects].some((e) => ASK_FIRST_EFFECTS.has(e)) && !(bundle.asksFirst ?? []).length) {
    fail("declares send, post, buy or delete, so asksFirst must say when it asks");
  }
}

export function checkLibrary(files, presets) {
  const errors = [];
  const byId = new Map();
  for (const { rel, dirKind, bundle } of files) {
    const fail = (message) => errors.push(`${rel}: ${message}`);
    if (bundle.kind !== dirKind) fail(`kind is "${bundle.kind}" but the file is under ${dirKind}`);
    if (typeof bundle.id !== "string") {
      fail("has no id");
      continue;
    }
    const base = rel.split("/").pop().replace(/\.md$/, "");
    if (bundle.id.split("/")[1] !== base) fail(`id "${bundle.id}" doesn't match the file name "${base}"`);
    if (byId.has(bundle.id)) fail(`id "${bundle.id}" is also ${byId.get(bundle.id).rel}`);
    else byId.set(bundle.id, { rel, bundle });
  }
  for (const { rel, bundle } of files) {
    const fail = (message) => errors.push(`${rel}: ${message}`);
    const params = new Map((bundle.params ?? []).map((p) => [p.key, p]));
    if (params.size !== (bundle.params ?? []).length) fail("declares a param twice");
    for (const param of bundle.params ?? []) {
      if (BUILT_IN_SLOTS.has(param.key)) fail(`param "${param.key}" is built in; don't declare it`);
      if (param.kind === "choice" && !param.options) fail(`choice param "${param.key}" has no options`);
      if (param.options && param.default !== undefined && !param.options.includes(param.default)) {
        fail(`param "${param.key}" defaults to "${param.default}", which isn't one of its options`);
      }
    }
    const used = new Set();
    for (const text of bundleTexts(bundle)) {
      for (const slot of slotsIn(text)) {
        used.add(slot);
        if (!params.has(slot) && !BUILT_IN_SLOTS.has(slot)) fail(`uses {${slot}}, which it doesn't declare`);
      }
    }
    if (hasHidden(JSON.stringify(bundle))) fail("has a NUL, zero-width, line-separator or bidi control character");
    for (const slot of slotsIn(bundle.schedule?.tz)) {
      used.add(slot);
      if (!BUILT_IN_SLOTS.has(slot) && !params.has(slot)) fail(`schedule.tz uses {${slot}}, which it doesn't declare`);
    }
    if (bundle.kind === "persona") {
      for (const { ref } of bundle.routines ?? []) {
        const target = byId.get(ref);
        if (!target || target.bundle.kind !== "routine") fail(`routine "${ref}" isn't in the library`);
        else for (const text of bundleTexts(target.bundle)) for (const slot of slotsIn(text)) used.add(slot);
      }
      for (const { ref } of bundle.staff ?? []) {
        const target = byId.get(ref);
        if (!target || target.bundle.kind !== "staff") fail(`staff "${ref}" isn't in the library`);
      }
      for (const key of bundle.hello?.ask ?? []) {
        if (!params.has(key)) fail(`hello asks for "${key}", which it doesn't declare`);
      }
      if (typeof bundle.playbook === "string") for (const message of playbookErrors(bundle.playbook)) fail(message);
      const shared = [
        bundle,
        ...(bundle.routines ?? []).map((r) => byId.get(r.ref)?.bundle),
        ...(bundle.staff ?? []).map((s) => byId.get(s.ref)?.bundle),
      ].filter(Boolean);
      const bytes = shared.reduce((sum, b) => sum + Buffer.byteLength(JSON.stringify(b)), 0);
      if (bytes > PERSONA_SHARE_BYTES) fail(`with its routines and staff it is ${bytes} bytes; a share is at most ${PERSONA_SHARE_BYTES}`);
    }
    for (const param of bundle.params ?? []) {
      if (!used.has(param.key)) fail(`declares {${param.key}} but never uses it`);
    }
    if (bundle.kind === "routine") {
      if (typeof bundle.target === "object" && bundle.target?.staff) {
        const target = byId.get(bundle.target.staff);
        if (!target || target.bundle.kind !== "staff") fail(`target staff "${bundle.target.staff}" isn't in the library`);
      }
      if (bundle.target === "director" && bundle.runOptions) fail("a routine that wakes the director takes no runOptions");
      if (bundle.target === "director" && typeof bundle.schedule?.cron === "string") {
        for (const message of scheduleErrors(bundle.schedule.cron)) fail(message);
      }
      if (bundle.mode === "on-demand" && !bundle.doneWhen) fail("an on-demand routine needs doneWhen, so it ends itself");
    }
    checkNeeds(bundle, presets, fail);
    const bytes = Buffer.byteLength(JSON.stringify(bundle));
    if (bytes > BUNDLE_BYTES) fail(`is ${bytes} bytes; a bundle is at most ${BUNDLE_BYTES}`);
  }
  return errors;
}

function presetIds() {
  const catalog = JSON.parse(readFileSync(catalogPath, "utf8"));
  return new Set(catalog.presets.map((p) => p.id));
}

function main() {
  const args = process.argv.slice(2);
  const check = args.includes("--check");
  if (args.some((a) => a !== "--check")) {
    console.error("usage: build-hq-library.mjs [--check]");
    process.exit(2);
  }
  let files;
  try {
    files = compileLibrary();
  } catch (error) {
    console.error(`✗ ${error.message}`);
    process.exit(1);
  }
  const errors = checkLibrary(files, presetIds());
  if (errors.length) {
    for (const error of errors) console.error(`✗ ${error}`);
    process.exit(1);
  }
  const bundles = files.map((f) => f.bundle);
  const existing = existsSync(outPath) ? JSON.parse(readFileSync(outPath, "utf8")) : null;
  const same = existing !== null && JSON.stringify(existing.bundles) === JSON.stringify(bundles);
  if (check) {
    if (!same) {
      console.error("✗ hq/library.json is stale: run node scripts/build-hq-library.mjs");
      process.exit(1);
    }
    console.log(`✓ hq/library.json matches its ${bundles.length} sources`);
    return;
  }
  const document = {
    $schema: "../schemas/hq-library.schema.json",
    schemaVersion: 1,
    updatedAt: same ? existing.updatedAt : new Date().toISOString().slice(0, 10),
    bundles,
  };
  writeFileSync(outPath, `${JSON.stringify(document, null, 2)}\n`);
  console.log(`✓ wrote hq/library.json (${bundles.length} bundles)`);
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) main();
