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
