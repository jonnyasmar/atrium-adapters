#!/usr/bin/env node

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { lstatSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { directoryDigest, runtimeFiles } from "./runtime-tree-digest.mjs";
import { canonicalGenerationViolation } from "./release-generation.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const registryPath = join(root, "registry.json");
const canonicalPath = join(root, "canonical-assets.json");
const skillAssetsPath = join(root, "skills/atrium/skill-assets.json");
const repository = "jonnyasmar/atrium-adapters";
const args = process.argv.slice(2);
const write = args.includes("--write");
const explicitCommitIndex = args.indexOf("--source-commit");

const registry = JSON.parse(readFileSync(registryPath, "utf8"));
const sourceCommit =
  explicitCommitIndex >= 0
    ? args[explicitCommitIndex + 1]
    : registry.source?.commit ?? git("rev-parse", "HEAD");

if (!/^[0-9a-f]{40}$/.test(sourceCommit ?? "")) {
  fail("source commit must be a full lowercase Git SHA");
}

function git(...gitArgs) {
  return execFileSync("git", gitArgs, { cwd: root, encoding: "utf8" }).trim();
}

function gitOptional(...gitArgs) {
  try {
    return execFileSync("git", gitArgs, {
      cwd: root,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return null;
  }
}

function fileDigest(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function sortJson(value) {
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

function canonicalJsonDigest(path) {
  const canonical = JSON.stringify(sortJson(JSON.parse(readFileSync(path, "utf8"))));
  return createHash("sha256").update(canonical).digest("hex");
}

function fail(message) {
  console.error(`release metadata: ${message}`);
  process.exitCode = 1;
}

const sha256Pattern = /^[0-9a-f]{64}$/;
const commitPattern = /^[0-9a-f]{40}$/;
const registryNamePattern = /^[a-z0-9][a-z0-9-]*$/;
const semverPattern =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;

function parseSemver(value) {
  const match = semverPattern.exec(value ?? "");
  if (!match) return null;
  return {
    core: match.slice(1, 4).map(Number),
    prerelease: match[4]?.split(".") ?? [],
  };
}

function compareSemver(left, right) {
  const a = parseSemver(left);
  const b = parseSemver(right);
  if (!a || !b) return null;
  for (let index = 0; index < 3; index += 1) {
    if (a.core[index] !== b.core[index]) return a.core[index] < b.core[index] ? -1 : 1;
  }
  if (a.prerelease.length === 0 || b.prerelease.length === 0) {
    return a.prerelease.length === b.prerelease.length ? 0 : a.prerelease.length === 0 ? 1 : -1;
  }
  for (let index = 0; index < Math.max(a.prerelease.length, b.prerelease.length); index += 1) {
    const aPart = a.prerelease[index];
    const bPart = b.prerelease[index];
    if (aPart === undefined || bPart === undefined) return aPart === undefined ? -1 : 1;
    if (aPart === bPart) continue;
    const aNumeric = /^\d+$/.test(aPart);
    const bNumeric = /^\d+$/.test(bPart);
    if (aNumeric && bNumeric) return BigInt(aPart) < BigInt(bPart) ? -1 : 1;
    if (aNumeric !== bNumeric) return aNumeric ? -1 : 1;
    return aPart < bPart ? -1 : 1;
  }
  return 0;
}

function validateRegistry(document) {
  if (document.schemaVersion !== 3) fail("registry schemaVersion must be 3");
  if (document.source?.repository !== repository) fail("registry source repository is not trusted");
  if (!commitPattern.test(document.source?.commit ?? "")) fail("registry source commit is invalid");
  if (!sha256Pattern.test(document.source?.sharedSha256 ?? "")) fail("registry shared digest is invalid");
  if (!sha256Pattern.test(document.source?.schemaSha256 ?? "")) fail("registry schema digest is invalid");
  const names = new Set();
  for (const entry of document.adapters ?? []) {
    if (!registryNamePattern.test(entry.name ?? "") || entry.name === "shared") {
      fail(`registry adapter name '${entry.name ?? ""}' is invalid or reserved`);
    }
    if (names.has(entry.name)) fail(`registry adapter '${entry.name}' is duplicated`);
    names.add(entry.name);
    if (entry.sdkVersion !== 2) fail(`registry adapter '${entry.name}' must use SDK 2`);
    if (!parseSemver(entry.version)) fail(`registry adapter '${entry.name}' has invalid version`);
    if (!Array.isArray(entry.platforms) || entry.platforms.length === 0) {
      fail(`registry adapter '${entry.name}' must declare at least one platform`);
    } else {
      const platforms = new Set();
      for (const platform of entry.platforms) {
        if (!["macos", "linux", "windows"].includes(platform) || platforms.has(platform)) {
          fail(`registry adapter '${entry.name}' has invalid or duplicate platform '${platform}'`);
        }
        platforms.add(platform);
      }
    }
    for (const platform of Object.keys(entry.install ?? {})) {
      if (!["macos", "linux", "windows"].includes(platform)) {
        fail(`registry adapter '${entry.name}' has install recipe for unknown platform '${platform}'`);
      }
    }
    if (!sha256Pattern.test(entry.contentSha256 ?? "")) {
      fail(`registry adapter '${entry.name}' content digest is invalid`);
    }
    for (const field of ["minAppVersion", "maxAppVersion"]) {
      if (entry[field] != null && !parseSemver(entry[field])) {
        fail(`registry adapter '${entry.name}' has invalid ${field}`);
      }
    }
    if (
      entry.minAppVersion != null &&
      entry.maxAppVersion != null &&
      compareSemver(entry.minAppVersion, entry.maxAppVersion) > 0
    ) {
      fail(`registry adapter '${entry.name}' has minAppVersion above maxAppVersion`);
    }
  }
  const tombstones = new Set();
  for (const tombstone of document.tombstones ?? []) {
    if (!registryNamePattern.test(tombstone.name ?? "") || !tombstone.reason?.trim()) {
      fail("registry tombstones require a valid name and nonempty reason");
    }
    if (tombstone.replacement != null && !registryNamePattern.test(tombstone.replacement)) {
      fail(`registry tombstone '${tombstone.name}' has an invalid replacement`);
    }
    if (tombstones.has(tombstone.name)) fail(`registry tombstone '${tombstone.name}' is duplicated`);
    tombstones.add(tombstone.name);
    if (names.has(tombstone.name)) {
      fail(`registry adapter '${tombstone.name}' cannot be released and tombstoned`);
    }
  }
}

function validRepoPath(value) {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    !value.startsWith("/") &&
    !value.includes("\\") &&
    value.split("/").every((part) => part.length > 0 && part !== "." && part !== "..")
  );
}

function validLeaf(value) {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value !== "." &&
    value !== ".." &&
    !value.includes("/") &&
    !value.includes("\\")
  );
}

function validateCanonical(document) {
  if (document.schemaVersion !== 2) fail("canonical schemaVersion must be 2");
  if (document.source?.repository !== repository) fail("canonical source repository is not trusted");
  if (!commitPattern.test(document.source?.commit ?? "")) fail("canonical source commit is invalid");
  if (!Number.isSafeInteger(document.source?.generation) || document.source.generation <= 0) {
    fail("canonical source generation must be a positive safe integer");
  }
  if (!Array.isArray(document.assets) || document.assets.length === 0) {
    fail("canonical asset manifest is empty");
    return;
  }
  const ids = new Set();
  const paths = new Set();
  let skillCount = 0;
  for (const asset of document.assets) {
    if (!asset.id || ids.has(asset.id)) fail(`canonical asset id '${asset.id ?? ""}' is invalid or duplicated`);
    ids.add(asset.id);
    if (!validRepoPath(asset.remotePath) || paths.has(asset.remotePath)) {
      fail(`canonical remotePath '${asset.remotePath ?? ""}' is invalid or duplicated`);
    }
    paths.add(asset.remotePath);
    if (!sha256Pattern.test(asset.sha256 ?? "")) fail(`canonical asset '${asset.id}' digest is invalid`);
    if (asset.target === "adapter-skill") skillCount += 1;
    else if (["atrium-home", "adapter-skill-reference"].includes(asset.target)) {
      if (!validLeaf(asset.destName)) fail(`canonical asset '${asset.id}' requires a leaf destName`);
    } else if (asset.target === "bundled-skill") {
      if (!validLeaf(asset.skillName)) fail(`canonical asset '${asset.id}' requires a leaf skillName`);
    } else fail(`canonical asset '${asset.id}' has unknown target '${asset.target}'`);
  }
  if (skillCount !== 1) fail(`canonical manifest requires exactly one adapter-skill, found ${skillCount}`);
}

function assertSourceContains(paths) {
  try {
    execFileSync("git", ["diff", "--quiet", sourceCommit, "--", ...paths], {
      cwd: root,
      stdio: "ignore",
    });
  } catch {
    fail(
      `source commit ${sourceCommit} does not contain the current release content; commit content first, then regenerate metadata`,
    );
  }
}

function assertRuntimeFilesArePinned(repoPath, directory) {
  const pinned = new Set(
    git("ls-tree", "-r", "--name-only", sourceCommit, "--", repoPath)
      .split("\n")
      .filter(Boolean),
  );
  for (const runtimePath of runtimeFiles(directory)) {
    const repositoryPath = `${repoPath}/${runtimePath}`;
    if (!pinned.has(repositoryPath)) {
      fail(`runtime file ${repositoryPath} is not present at source commit ${sourceCommit}`);
    }
  }
}

const sharedPath = join(root, "adapters/shared");
const sharedMetadata = lstatSync(sharedPath);
const sharedIsRealDirectory =
  sharedMetadata.isDirectory() && !sharedMetadata.isSymbolicLink();
if (!sharedIsRealDirectory) fail("adapters/shared must be a real directory");

const schemaPath = join(root, "schemas/adapter.schema.json");
const schemaMetadata = lstatSync(schemaPath);
const schemaIsRegularFile = schemaMetadata.isFile() && !schemaMetadata.isSymbolicLink();
if (!schemaIsRegularFile) fail("schemas/adapter.schema.json must be a regular file");

const releasePaths = ["adapters/shared", "schemas/adapter.schema.json"];
const computedAdapterDigests = new Map();
for (const entry of registry.adapters) {
  const path = join(root, "adapters", entry.name);
  const metadata = lstatSync(path);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    fail(`adapter path adapters/${entry.name} must be a real directory`);
    continue;
  }
  releasePaths.push(`adapters/${entry.name}`);
  assertRuntimeFilesArePinned(`adapters/${entry.name}`, path);
  computedAdapterDigests.set(entry.name, directoryDigest(path));
}
if (sharedIsRealDirectory) assertRuntimeFilesArePinned("adapters/shared", sharedPath);

const canonical = JSON.parse(readFileSync(canonicalPath, "utf8"));
const canonicalAssetDigests = new Map();
for (const asset of canonical.assets) {
  const metadata = asset.remotePath ? lstatSync(join(root, asset.remotePath)) : null;
  if (!metadata?.isFile() || metadata.isSymbolicLink()) {
    fail(`canonical asset '${asset.id ?? "<unknown>"}' must have a regular-file remotePath`);
    continue;
  }
  releasePaths.push(asset.remotePath);
  canonicalAssetDigests.set(asset.id, fileDigest(join(root, asset.remotePath)));
}
assertSourceContains([...new Set(releasePaths)]);

const expectedSource = {
  repository,
  commit: sourceCommit,
  sharedSha256: sharedIsRealDirectory ? directoryDigest(sharedPath) : "",
  schemaSha256: schemaIsRegularFile ? canonicalJsonDigest(schemaPath) : "",
};

const expectedRegistry = structuredClone(registry);
expectedRegistry.schemaVersion = 3;
expectedRegistry.source = expectedSource;
expectedRegistry.tombstones ??= [];
for (const entry of expectedRegistry.adapters) {
  entry.contentSha256 = computedAdapterDigests.get(entry.name);
  entry.maxAppVersion ??= null;
}

const expectedCanonical = structuredClone(canonical);
expectedCanonical.schemaVersion = 2;
expectedCanonical.source = {
  repository,
  commit: sourceCommit,
  generation: canonical.source?.generation,
};
for (const asset of expectedCanonical.assets) {
  asset.sha256 = canonicalAssetDigests.get(asset.id) ?? "";
}

const predecessorBody = gitOptional("show", `${sourceCommit}^:canonical-assets.json`);
if (predecessorBody == null) {
  fail(`canonical predecessor for ${sourceCommit} is unavailable; fetch full git history`);
} else {
  try {
    const predecessor = JSON.parse(predecessorBody);
    const violation = canonicalGenerationViolation(
      predecessor,
      expectedCanonical,
      sourceCommit,
    );
    if (violation != null) fail(violation);
  } catch (error) {
    fail(`canonical predecessor manifest is invalid: ${error}`);
  }
}

validateRegistry(expectedRegistry);
validateCanonical(expectedCanonical);

const skillAssets = JSON.parse(readFileSync(skillAssetsPath, "utf8"));
const expectedSkillAssets = {
  version: 1,
  references: skillAssets.references.map((reference) => {
    const name = typeof reference === "string" ? reference : reference.name;
    return name;
  }),
};

const documents = [
  [registryPath, registry, expectedRegistry],
  [canonicalPath, canonical, expectedCanonical],
  [skillAssetsPath, skillAssets, expectedSkillAssets],
];

if (write) {
  for (const [path, , expected] of documents) {
    writeFileSync(path, `${JSON.stringify(expected, null, 2)}\n`);
  }
  console.log(`release metadata: wrote immutable metadata for ${sourceCommit}`);
} else {
  for (const [path, actual, expected] of documents) {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
      fail(`${relative(root, path)} is stale; run scripts/generate-release-metadata.mjs --write`);
    }
  }
  if (!process.exitCode) {
    console.log(`release metadata: verified immutable metadata for ${sourceCommit}`);
  }
}
