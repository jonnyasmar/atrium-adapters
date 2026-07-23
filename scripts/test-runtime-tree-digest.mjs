#!/usr/bin/env node

import { mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  canonicalJsonDigest,
  directoryDigest,
  methodsSchemaDigest,
} from "./runtime-tree-digest.mjs";

const fixture = mkdtempSync(join(tmpdir(), "atrium-adapter-digest-"));
try {
  mkdirSync(join(fixture, "nested"));
  mkdirSync(join(fixture, "tests"));
  mkdirSync(join(fixture, "__pycache__"));
  writeFileSync(join(fixture, "alpha.txt"), "alpha\n");
  writeFileSync(join(fixture, "nested", "β.txt"), "beta\n");
  writeFileSync(join(fixture, "nested", ".DS_Store"), "ignored\n");
  writeFileSync(join(fixture, "nested", ".atrium-managed.json"), "ignored\n");
  writeFileSync(join(fixture, "tests", "fixture.txt"), "ignored\n");
  writeFileSync(join(fixture, "__pycache__", "runtime.cpython-314.pyc"), "ignored\n");

  const actual = directoryDigest(fixture);
  const expected = "c8f4063149772f0e2af8e37ed7dd9ee822d9a991e338c0d4ea6ee917cba998f9";
  if (actual !== expected) {
    throw new Error(`runtime tree digest mismatch: expected ${expected}, got ${actual}`);
  }

  symlinkSync(join(fixture, "alpha.txt"), join(fixture, "link.txt"));
  try {
    directoryDigest(fixture);
    throw new Error("runtime tree digest accepted a symlink");
  } catch (error) {
    if (!String(error).includes("contains a symlink")) throw error;
  }
  rmSync(join(fixture, "link.txt"));

  rmSync(join(fixture, "nested", ".DS_Store"));
  symlinkSync(join(fixture, "alpha.txt"), join(fixture, "nested", ".DS_Store"));
  try {
    directoryDigest(fixture);
    throw new Error("runtime tree digest ignored a metadata-named symlink");
  } catch (error) {
    if (!String(error).includes("contains a symlink")) throw error;
  }
  rmSync(join(fixture, "nested", ".DS_Store"));

  rmSync(join(fixture, "tests"), { recursive: true });
  symlinkSync(join(fixture, "alpha.txt"), join(fixture, "tests"));
  try {
    directoryDigest(fixture);
    throw new Error("runtime tree digest ignored a test-directory symlink");
  } catch (error) {
    if (!String(error).includes("contains a symlink")) throw error;
  }
  console.log("runtime tree digest: golden fixture and symlink rejection passed");
} finally {
  rmSync(fixture, { recursive: true, force: true });
}

// --- methods-schema digest change detection ---
// methodsSchemaSha256 covers methods/* only; schemaSha256 is adapter.schema.json alone.
const schemaFixture = mkdtempSync(join(tmpdir(), "atrium-schema-digest-"));
try {
  mkdirSync(join(schemaFixture, "methods"));
  writeFileSync(
    join(schemaFixture, "adapter.schema.json"),
    `${JSON.stringify({ $id: "adapter", type: "object", properties: { a: { type: "string" } } }, null, 2)}\n`,
  );
  writeFileSync(
    join(schemaFixture, "methods", "hooks.schema.json"),
    `${JSON.stringify({ $id: "hooks", type: "object", required: ["event"] }, null, 2)}\n`,
  );
  writeFileSync(
    join(schemaFixture, "methods", "check_update.schema.json"),
    `${JSON.stringify({ $id: "check_update", type: "object" }, null, 2)}\n`,
  );

  const baselineMethods = methodsSchemaDigest(schemaFixture);
  const baselineAdapter = canonicalJsonDigest(join(schemaFixture, "adapter.schema.json"));
  if (!/^[0-9a-f]{64}$/.test(baselineMethods)) {
    throw new Error(`methods-schema digest: invalid methods digest ${baselineMethods}`);
  }
  if (!/^[0-9a-f]{64}$/.test(baselineAdapter)) {
    throw new Error(`methods-schema digest: invalid adapter digest ${baselineAdapter}`);
  }

  // Key reordering / whitespace must not change the canonical methods digest.
  writeFileSync(
    join(schemaFixture, "methods", "hooks.schema.json"),
    JSON.stringify({ required: ["event"], type: "object", $id: "hooks" }),
  );
  const reordered = methodsSchemaDigest(schemaFixture);
  if (reordered !== baselineMethods) {
    throw new Error("methods-schema digest: canonical JSON reordering changed digest");
  }
  if (canonicalJsonDigest(join(schemaFixture, "adapter.schema.json")) !== baselineAdapter) {
    throw new Error("methods-schema digest: adapter schemaSha256 drifted on methods reordering");
  }

  // Semantic change to a methods schema must change methodsSchemaSha256 while
  // schemaSha256 (adapter.schema.json alone) stays stable.
  writeFileSync(
    join(schemaFixture, "methods", "hooks.schema.json"),
    `${JSON.stringify({ $id: "hooks", type: "object", required: ["event", "payload"] }, null, 2)}\n`,
  );
  const methodsChanged = methodsSchemaDigest(schemaFixture);
  if (methodsChanged === baselineMethods) {
    throw new Error("methods-schema digest: methods change was not detected");
  }
  const adapterAfterMethodsChange = canonicalJsonDigest(
    join(schemaFixture, "adapter.schema.json"),
  );
  if (adapterAfterMethodsChange !== baselineAdapter) {
    throw new Error(
      "methods-schema digest: schemaSha256 changed when only methods/* changed",
    );
  }

  // adapter.schema.json change must move schemaSha256 but not methodsSchemaSha256.
  writeFileSync(
    join(schemaFixture, "adapter.schema.json"),
    `${JSON.stringify({ $id: "adapter", type: "object", properties: { b: { type: "number" } } }, null, 2)}\n`,
  );
  const adapterChanged = canonicalJsonDigest(join(schemaFixture, "adapter.schema.json"));
  if (adapterChanged === baselineAdapter) {
    throw new Error("methods-schema digest: adapter schema change was not detected");
  }
  const methodsAfterAdapterChange = methodsSchemaDigest(schemaFixture);
  if (methodsAfterAdapterChange !== methodsChanged) {
    throw new Error(
      "methods-schema digest: methodsSchemaSha256 changed when only adapter.schema.json changed",
    );
  }

  console.log("runtime tree digest: methods-schema digest change detection passed");
} finally {
  rmSync(schemaFixture, { recursive: true, force: true });
}
