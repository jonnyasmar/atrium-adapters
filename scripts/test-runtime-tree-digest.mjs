#!/usr/bin/env node

import { mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { directoryDigest } from "./runtime-tree-digest.mjs";

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
