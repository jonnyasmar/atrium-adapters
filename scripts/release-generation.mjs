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

export function compareSemver(left, right) {
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

export function canonicalGenerationViolation(previous, current, sourceCommit) {
  if (previous == null || typeof previous !== "object") {
    return "canonical predecessor manifest is unavailable";
  }
  const previousGeneration = Number.isSafeInteger(previous.source?.generation)
    ? previous.source.generation
    : 0;
  const currentGeneration = current.source?.generation;
  if (!Number.isSafeInteger(currentGeneration) || currentGeneration <= 0) {
    return "canonical source generation must be a positive safe integer";
  }
  if (currentGeneration < previousGeneration) {
    return `canonical source generation ${currentGeneration} is below predecessor generation ${previousGeneration}`;
  }

  const sourceChanged = previous.source?.commit !== sourceCommit;
  const assetsChanged = JSON.stringify(previous.assets ?? []) !== JSON.stringify(current.assets ?? []);
  if ((sourceChanged || assetsChanged) && currentGeneration <= previousGeneration) {
    return `canonical release changed without advancing generation ${previousGeneration}`;
  }
  return null;
}

/**
 * Reject generations that would regress (or collide with) the currently published
 * tip (origin/main, else main). New publications must use a strictly greater
 * generation than the tip; re-verifying the same tip publication is allowed.
 */
export function publishedTipGenerationViolation(tip, current) {
  if (tip == null || typeof tip !== "object") return null;

  const tipGeneration = Number.isSafeInteger(tip.source?.generation) ? tip.source.generation : 0;
  const currentGeneration = current.source?.generation;
  if (!Number.isSafeInteger(currentGeneration) || currentGeneration <= 0) {
    return "canonical source generation must be a positive safe integer";
  }
  if (currentGeneration < tipGeneration) {
    return `canonical source generation ${currentGeneration} is below published tip generation ${tipGeneration}`;
  }
  if (currentGeneration === tipGeneration) {
    const sameCommit = tip.source?.commit === current.source?.commit;
    const sameAssets =
      JSON.stringify(tip.assets ?? []) === JSON.stringify(current.assets ?? []);
    if (!sameCommit || !sameAssets) {
      return `canonical source generation ${currentGeneration} is not strictly greater than published tip generation ${tipGeneration}`;
    }
  }
  return null;
}

/**
 * When computed contentSha256 differs from the committed registry entry, the
 * adapter version must have been bumped above the previous release version
 * whenever the tree content actually changed.
 */
export function contentVersionCouplingViolation({
  adapterName,
  committedDigest,
  computedDigest,
  committedVersion,
  previousVersion,
  previousDigest,
}) {
  if (computedDigest === committedDigest) return null;
  // Committed digest is stale but tree matches the previous release — --write
  // may refresh the digest without a version bump.
  if (previousDigest != null && previousDigest === computedDigest) return null;
  if (previousVersion == null) return null;

  const cmp = compareSemver(committedVersion, previousVersion);
  if (cmp == null) {
    return `adapter '${adapterName}' has invalid version '${committedVersion ?? ""}'`;
  }
  if (cmp <= 0) {
    return `adapter '${adapterName}' content changed but version was not bumped (still ${committedVersion}; previous release ${previousVersion})`;
  }
  return null;
}

/** Decide whether --write should persist documents after validation. */
export function releaseWriteDecision(write, validationFailed) {
  if (!write) return "verify";
  if (validationFailed) return "refuse";
  return "write";
}
