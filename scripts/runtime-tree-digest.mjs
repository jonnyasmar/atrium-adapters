import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative, sep } from "node:path";

const ignoredMetadata = new Set([".DS_Store", ".atrium-managed.json"]);

export function runtimeFiles(dir, prefix = dir) {
  const files = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const absolute = join(dir, entry.name);
    const rel = relative(prefix, absolute).split(sep).join("/");
    if (entry.isSymbolicLink()) {
      throw new Error(`managed runtime tree contains a symlink: ${rel}`);
    }
    if (!entry.isDirectory() && !entry.isFile()) {
      throw new Error(`managed runtime tree contains an unsupported file type: ${rel}`);
    }
    if (ignoredMetadata.has(entry.name)) continue;
    if (rel === "tests" || rel.startsWith("tests/")) continue;
    if (rel.split("/").includes("__pycache__") || rel.endsWith(".pyc")) continue;
    if (entry.isDirectory()) files.push(...runtimeFiles(absolute, prefix));
    else if (entry.isFile()) files.push(rel);
  }
  return files.sort((left, right) =>
    Buffer.compare(Buffer.from(left, "utf8"), Buffer.from(right, "utf8")),
  );
}

export function directoryDigest(dir) {
  const hash = createHash("sha256");
  for (const rel of runtimeFiles(dir)) {
    const bytes = readFileSync(join(dir, rel));
    const pathBytes = Buffer.from(rel, "utf8");
    const pathLength = Buffer.alloc(8);
    pathLength.writeBigUInt64BE(BigInt(pathBytes.length));
    const bodyLength = Buffer.alloc(8);
    bodyLength.writeBigUInt64BE(BigInt(bytes.length));
    hash.update(pathLength);
    hash.update(pathBytes);
    hash.update(bodyLength);
    hash.update(bytes);
  }
  return hash.digest("hex");
}

export function sortJson(value) {
  if (Array.isArray(value)) return value.map(sortJson);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, sortJson(value[key])]),
    );
  }
  return value;
}

export function canonicalJsonBytes(path) {
  const canonical = JSON.stringify(sortJson(JSON.parse(readFileSync(path, "utf8"))));
  return Buffer.from(canonical, "utf8");
}

export function canonicalJsonDigest(path) {
  return createHash("sha256").update(canonicalJsonBytes(path)).digest("hex");
}

/**
 * methodsSchemaSha256 covers schemas/methods/*.json only so method contracts
 * cannot drift without changing the registry pin. Paths are length-prefixed
 * UTF-8 relative to schemas/ (e.g. methods/hooks.schema.json); body is
 * canonical JSON bytes; paths are sorted. adapter.schema.json is intentionally
 * excluded — that file is pinned separately via source.schemaSha256.
 */
export function methodsSchemaDigest(schemasDir) {
  const methodsDir = join(schemasDir, "methods");
  let methodNames = [];
  try {
    methodNames = readdirSync(methodsDir).filter((name) => name.endsWith(".json"));
  } catch {
    methodNames = [];
  }
  methodNames.sort((left, right) =>
    Buffer.compare(Buffer.from(left, "utf8"), Buffer.from(right, "utf8")),
  );

  const hash = createHash("sha256");
  for (const name of methodNames) {
    const rel = `methods/${name}`;
    const path = join(methodsDir, name);
    const pathBytes = Buffer.from(rel, "utf8");
    const body = canonicalJsonBytes(path);
    const pathLength = Buffer.alloc(8);
    pathLength.writeBigUInt64BE(BigInt(pathBytes.length));
    const bodyLength = Buffer.alloc(8);
    bodyLength.writeBigUInt64BE(BigInt(body.length));
    hash.update(pathLength);
    hash.update(pathBytes);
    hash.update(bodyLength);
    hash.update(body);
  }
  return hash.digest("hex");
}
