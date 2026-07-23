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
