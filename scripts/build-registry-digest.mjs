#!/usr/bin/env node
// The MCP Registry digest atrium's Settings > Connectors browses beside the
// curated catalog: every active, latest-version server from the official
// registry, slimmed to what browsing and adding one need, one per line,
// gzipped. Crawled once here, so no atrium install ever pages the registry
// itself.
//
// Usage:
//   node scripts/build-registry-digest.mjs                 # crawl the registry
//   node scripts/build-registry-digest.mjs --from <dir>    # build from saved pages
//   node scripts/build-registry-digest.mjs --out <file>    # default connectors/registry-digest.ndjson.gz
//   node scripts/build-registry-digest.mjs --listings-only # refresh the curated lines, keep the servers
//
// The first line is a header ({schemaVersion, generatedAt, registry,
// servers, listings, vendors}); each line after it is {"server": {...}},
// then one {"listing": {...}} per entry of connectors/official-listings.json
// (official servers the registry doesn't list), one {"vendor": {...}} per
// entry of connectors/vendors.json (who owns which product names), and one
// {"genericWords": [...]} (words no domain's name makes a brand). A build that
// predates them reads no `server` in those lines and skips them. atrium
// classifies, ranks and collapses near-duplicates itself when it reads the
// file.

import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync, gzipSync } from "node:zlib";

const REGISTRY = "https://registry.modelcontextprotocol.io";
const LIST = "/v0.1/servers";
const PAGE_LIMIT = 100;
const PACE_MS = 300;
const DESCRIPTION_CHARS = 300;
const FIELD_CHARS = 200;

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const option = (name) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const out = resolve(option("--out") ?? join(root, "connectors/registry-digest.ndjson.gz"));
const from = option("--from");
const listingsOnly = args.includes("--listings-only");

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
// A link a client may open or the daemon may fetch: https, with a host and no
// credentials in it. Any other scheme (javascript:, data:, file:, an app's
// own) is dropped here, before it reaches anyone.
const https = (url) => {
  if (typeof url !== "string") return undefined;
  try {
    const parsed = new URL(url.trim());
    const web = parsed.protocol === "https:" && parsed.hostname && !parsed.username && !parsed.password;
    return web ? url.trim() : undefined;
  } catch {
    return undefined;
  }
};
const clip = (text, chars) =>
  typeof text === "string" && text.trim() ? [...text.trim()].slice(0, chars).join("") : undefined;
const compact = (object) =>
  Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined));

async function* crawl() {
  let cursor;
  let pages = 0;
  for (;;) {
    const url = new URL(LIST, REGISTRY);
    url.searchParams.set("limit", String(PAGE_LIMIT));
    url.searchParams.set("version", "latest");
    if (cursor) url.searchParams.set("cursor", cursor);
    let page;
    for (let attempt = 1; ; attempt++) {
      const response = await fetch(url, {
        headers: { accept: "application/json", "user-agent": "atrium-adapters/registry-digest" },
        signal: AbortSignal.timeout(30_000),
      }).catch((error) => ({ ok: false, status: String(error) }));
      if (response.ok) {
        page = await response.json();
        break;
      }
      if (attempt >= 5) throw new Error(`${url}: ${response.status}`);
      await sleep(attempt * 5_000);
    }
    pages += 1;
    if (pages % 50 === 0) console.error(`… ${pages} pages`);
    yield page;
    cursor = page.metadata?.nextCursor;
    if (!cursor) return;
    await sleep(PACE_MS);
  }
}

function* saved(dir) {
  const files = readdirSync(dir)
    .filter((name) => name.endsWith(".json"))
    .sort();
  for (const file of files) yield JSON.parse(readFileSync(join(dir, file), "utf8"));
}

function slimArgument(argument) {
  if (!argument || typeof argument !== "object") return undefined;
  return compact({
    type: argument.type,
    name: argument.name,
    value: argument.value,
    default: argument.default,
    valueHint: argument.valueHint,
    isRequired: argument.isRequired || undefined,
    description: clip(argument.description, FIELD_CHARS),
    variables: argument.variables,
  });
}

function slimVariable(variable) {
  return compact({
    name: variable.name,
    description: clip(variable.description, FIELD_CHARS),
    isRequired: variable.isRequired || undefined,
    isSecret: variable.isSecret || undefined,
    default: variable.default,
  });
}

function slimRemote(remote) {
  if (!["streamable-http", "sse"].includes(remote?.type) || !https(remote.url)) return undefined;
  return compact({
    type: remote.type,
    url: remote.url,
    headers: remote.headers?.length ? remote.headers.map(slimVariable) : undefined,
    variables: remote.variables,
  });
}

function slimPackage(pkg) {
  if (!pkg?.registryType || !pkg.identifier) return undefined;
  const list = (items, slim) => (items?.length ? items.map(slim).filter(Boolean) : undefined);
  return compact({
    registryType: pkg.registryType,
    identifier: pkg.identifier,
    version: pkg.version,
    runtimeHint: pkg.runtimeHint,
    transport: pkg.transport?.type ? { type: pkg.transport.type } : undefined,
    environmentVariables: list(pkg.environmentVariables, slimVariable),
    packageArguments: list(pkg.packageArguments, slimArgument),
    runtimeArguments: list(pkg.runtimeArguments, slimArgument),
  });
}

function slim(server) {
  const icon = (server.icons ?? []).map((icon) => https(icon?.src)).find(Boolean);
  const repositoryUrl = https(server.repository?.url);
  const repository = repositoryUrl
    ? compact({ url: repositoryUrl, subfolder: server.repository.subfolder || undefined })
    : undefined;
  const remotes = (server.remotes ?? []).map(slimRemote).filter(Boolean);
  const packages = (server.packages ?? []).map(slimPackage).filter(Boolean);
  return compact({
    name: server.name,
    title: clip(server.title, FIELD_CHARS),
    description: clip(server.description, DESCRIPTION_CHARS),
    version: server.version,
    websiteUrl: https(server.websiteUrl),
    repository,
    icons: icon ? [{ src: icon }] : undefined,
    remotes: remotes.length ? remotes : undefined,
    packages: packages.length ? packages : undefined,
  });
}

// The official listings (check-schemas.py validates the file itself), as
// the lines atrium reads: the server as the registry would hold it, and what
// atrium shows beside it.
const listingLines = JSON.parse(readFileSync(join(root, "connectors/official-listings.json"), "utf8"))
  .listings.map((listing) =>
    JSON.stringify({
      listing: compact({
        server: slim(listing.server),
        vendor: listing.vendor,
        category: listing.category,
        status: listing.status,
        docsUrl: https(listing.docsUrl),
        why: listing.why,
        owns: listing.owns,
      }),
    }),
  );

// The vendors as the index reads them: their sources stay in the file.
const vendorsDocument = JSON.parse(readFileSync(join(root, "connectors/vendors.json"), "utf8"));
const vendorLines = vendorsDocument.vendors.map((vendor) =>
  JSON.stringify({
    vendor: compact({
      owns: vendor.owns,
      roots: vendor.roots.map((item) => item.root),
      searchedAs: vendor.searchedAs,
      endpoints: vendor.endpoints?.map((item) => item.url),
    }),
  }),
);
const genericLine = JSON.stringify({ genericWords: vendorsDocument.genericWords });

let header;
let serverLines;
let read = 0;
if (listingsOnly) {
  // The kept digest's servers as they are; only its listings are replaced.
  const [first, ...rest] = gunzipSync(readFileSync(out)).toString("utf8").split("\n");
  header = JSON.parse(first);
  serverLines = rest.filter((line) => line.startsWith('{"server":'));
  read = serverLines.length;
} else {
  const servers = new Map();
  for await (const page of from ? saved(from) : crawl()) {
    for (const entry of page.servers ?? []) {
      read += 1;
      const status = entry._meta?.["io.modelcontextprotocol.registry/official"]?.status ?? "active";
      const name = entry.server?.name;
      if (status !== "active" || typeof name !== "string" || !name.includes("/")) continue;
      servers.set(name, slim(entry.server));
    }
  }
  const names = [...servers.keys()].sort();
  header = { schemaVersion: 1, generatedAt: new Date().toISOString(), registry: REGISTRY };
  serverLines = names.map((name) => JSON.stringify({ server: servers.get(name) }));
}
header = {
  ...header,
  servers: serverLines.length,
  listings: listingLines.length,
  vendors: vendorLines.length,
};

const lines = [JSON.stringify(header), ...serverLines, ...listingLines, ...vendorLines, genericLine];
const body = Buffer.from(`${lines.join("\n")}\n`, "utf8");
const gz = gzipSync(body, { level: 9 });
writeFileSync(out, gz);
console.log(
  `✓ ${serverLines.length} servers (of ${read} read), ${listingLines.length} listings and ${vendorLines.length} vendors → ${out}: ${(body.length / 1e6).toFixed(1)} MB, ${(gz.length / 1e6).toFixed(1)} MB gzipped`,
);
