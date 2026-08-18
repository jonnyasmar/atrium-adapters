#!/usr/bin/env node

import {
  canonicalGenerationViolation,
  contentVersionCouplingViolation,
  publishedTipGenerationViolation,
  releaseWriteDecision,
  skillReferenceParityViolation,
  sourceCommitAncestryViolation,
} from "./release-generation.mjs";

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

function expectTipAccepted(tip, current, label) {
  const violation = publishedTipGenerationViolation(tip, current);
  if (violation != null) throw new Error(`${label}: ${violation}`);
}

function expectTipRejected(tip, current, label) {
  if (publishedTipGenerationViolation(tip, current) == null) {
    throw new Error(`${label}: published tip generation was unexpectedly accepted`);
  }
}

function expectCouplingAccepted(input, label) {
  const violation = contentVersionCouplingViolation(input);
  if (violation != null) throw new Error(`${label}: ${violation}`);
}

function expectCouplingRejected(input, label) {
  if (contentVersionCouplingViolation(input) == null) {
    throw new Error(`${label}: content/version coupling was unexpectedly accepted`);
  }
}

// --- source commit ancestry ---
if (sourceCommitAncestryViolation(commitOne, commitTwo, true) != null) {
  throw new Error("source ancestry: ancestor was unexpectedly rejected");
}
if (sourceCommitAncestryViolation(commitOne, commitTwo, false) == null) {
  throw new Error("source ancestry: rebased-away source was unexpectedly accepted");
}
console.log("release generation: source-ancestry rejection passed");

// --- skill reference parity ---
const publishedReferences = [
  { target: "adapter-skill-reference", destName: "capture.md" },
  { target: "adapter-skill-reference", destName: "computer-use.md" },
  { target: "bundled-skill", skillName: "unrelated" },
];
if (
  skillReferenceParityViolation(
    ["capture.md", "computer-use.md"],
    publishedReferences,
  ) != null
) {
  throw new Error(
    "skill reference parity: matching manifests were unexpectedly rejected",
  );
}
if (
  skillReferenceParityViolation(
    ["capture.md", "computer-use.md"],
    publishedReferences.slice(0, 1),
  ) == null
) {
  throw new Error(
    "skill reference parity: missing canonical reference was unexpectedly accepted",
  );
}
if (
  skillReferenceParityViolation(["capture.md"], publishedReferences) == null
) {
  throw new Error(
    "skill reference parity: undeclared canonical reference was unexpectedly accepted",
  );
}
console.log("release generation: skill-reference parity passed");

// --- predecessor monotonicity (existing) ---
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

// --- tip-regression rejection ---
expectTipAccepted(null, manifest(commitOne, 1), "missing tip skipped");
expectTipAccepted(
  { assets: assetOne },
  manifest(commitOne, 1),
  "tip without generation treated as 0",
);
expectTipAccepted(
  manifest(commitOne, 3),
  manifest(commitOne, 3),
  "same tip publication re-verify",
);
expectTipAccepted(
  manifest(commitOne, 3),
  manifest(commitTwo, 4, assetTwo),
  "tip advanced strictly greater",
);
expectTipRejected(
  manifest(commitTwo, 5),
  manifest(commitOne, 3),
  "tip regression below published generation",
);
expectTipRejected(
  manifest(commitOne, 4),
  manifest(commitTwo, 4, assetTwo),
  "tip collision at same generation with different release",
);
console.log("release generation: tip-regression rejection passed");

// --- version-bump enforcement ---
const digestOld = "a".repeat(64);
const digestNew = "b".repeat(64);
expectCouplingAccepted(
  {
    adapterName: "demo",
    committedDigest: digestOld,
    computedDigest: digestOld,
    committedVersion: "1.0.0",
    previousVersion: "1.0.0",
    previousDigest: digestOld,
  },
  "unchanged content",
);
expectCouplingAccepted(
  {
    adapterName: "demo",
    committedDigest: digestOld,
    computedDigest: digestNew,
    committedVersion: "1.1.0",
    previousVersion: "1.0.0",
    previousDigest: digestOld,
  },
  "content change with version bump",
);
expectCouplingAccepted(
  {
    adapterName: "demo",
    committedDigest: "c".repeat(64),
    computedDigest: digestOld,
    committedVersion: "1.0.0",
    previousVersion: "1.0.0",
    previousDigest: digestOld,
  },
  "stale committed digest only",
);
expectCouplingAccepted(
  {
    adapterName: "demo",
    committedDigest: digestOld,
    computedDigest: digestNew,
    committedVersion: "1.0.0",
    previousVersion: null,
    previousDigest: null,
  },
  "new adapter without previous release",
);
expectCouplingRejected(
  {
    adapterName: "demo",
    committedDigest: digestOld,
    computedDigest: digestNew,
    committedVersion: "1.0.0",
    previousVersion: "1.0.0",
    previousDigest: digestOld,
  },
  "content change without version bump",
);
expectCouplingRejected(
  {
    adapterName: "demo",
    committedDigest: digestOld,
    computedDigest: digestNew,
    committedVersion: "1.0.0",
    previousVersion: "1.1.0",
    previousDigest: digestOld,
  },
  "content change with version regression",
);
console.log("release generation: version-bump enforcement passed");

// --- write-refusal on validation failure ---
if (releaseWriteDecision(true, true) !== "refuse") {
  throw new Error("write-refusal: expected refuse when validation failed");
}
if (releaseWriteDecision(true, false) !== "write") {
  throw new Error("write-refusal: expected write when validation passed");
}
if (releaseWriteDecision(false, false) !== "verify") {
  throw new Error("write-refusal: expected verify without --write");
}
if (releaseWriteDecision(false, true) !== "verify") {
  throw new Error("write-refusal: expected verify without --write even if failed");
}
console.log("release generation: write-refusal on validation failure passed");

console.log("release generation: monotonic canonical publication passed");
