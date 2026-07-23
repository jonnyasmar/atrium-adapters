#!/usr/bin/env node

import { canonicalGenerationViolation } from "./release-generation.mjs";

const commitOne = "1".repeat(40);
const commitTwo = "2".repeat(40);
const assetOne = [{ id: "skill", sha256: "a".repeat(64) }];
const assetTwo = [{ id: "skill", sha256: "b".repeat(64) }];
const manifest = (commit, generation, assets = assetOne) => ({
  source: { commit, generation },
  assets,
});

function expectAccepted(previous, current, sourceCommit, label) {
  const violation = canonicalGenerationViolation(previous, current, sourceCommit);
  if (violation != null) throw new Error(`${label}: ${violation}`);
}

function expectRejected(previous, current, sourceCommit, label) {
  if (canonicalGenerationViolation(previous, current, sourceCommit) == null) {
    throw new Error(`${label}: release generation was unexpectedly accepted`);
  }
}

expectAccepted(
  { source: { commit: commitOne }, assets: [] },
  manifest(commitTwo, 1),
  commitTwo,
  "schema migration",
);
expectAccepted(
  manifest(commitOne, 3),
  manifest(commitOne, 3),
  commitOne,
  "unchanged release",
);
expectAccepted(
  manifest(commitOne, 3),
  manifest(commitTwo, 4, assetTwo),
  commitTwo,
  "advanced release",
);
expectRejected(
  manifest(commitOne, 3),
  manifest(commitTwo, 3),
  commitTwo,
  "source change without bump",
);
expectRejected(
  manifest(commitOne, 3),
  manifest(commitOne, 3, assetTwo),
  commitOne,
  "content change without bump",
);
expectRejected(
  manifest(commitOne, 3),
  manifest(commitOne, 2),
  commitOne,
  "generation regression",
);

console.log("release generation: monotonic canonical publication passed");
