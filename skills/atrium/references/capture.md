# Inspecting a QA Capture bundle (CAP-#)

Read this when the user references a CAP-# — assigns you a capture task, drops `CAP-381` in a message, or asks you to "look at this recording." A capture bundle is a recorded session: `video.mov` + `transcript.jsonl` + `events.jsonl` + `chapters.json` + `annotations.json`.

**Drive everything through `atrium capture`. Never shell out to `ffmpeg` / `sips` / `magick`** — atrium ships native AVFoundation equivalents that are faster and need no third-party binary. **Run `"$ATRIUM_CLI_PATH" capture --help` (and `<verb> --help`) when unsure of flags** — the CLI is the source of truth.

## The recipe, in order

```bash
# 1. Bundle paths + counts + status.
"$ATRIUM_CLI_PATH" capture show CAP-381 --json
```

Returns absolute paths to all five files plus line/chapter/annotation counts. Read the JSONL/JSON directly via `Read` — they're small, well-structured, and the highest-bandwidth signal in the bundle (transcript = what the user narrated; events = input; chapters = moments the user explicitly marked; annotations = pixel-space rects of what they drew on).

```bash
# 2. Still frame at a timestamp — the LLM-friendly path.
"$ATRIUM_CLI_PATH" capture screenshot CAP-381 --at 16 --out /tmp/cap381_at16.png

# Crop a region (pixel-space, top-left origin).
"$ATRIUM_CLI_PATH" capture screenshot CAP-381 --at 16 --crop 1380,920,1150,900 --out /tmp/crop.png

# Downsample so the longest edge is ≤ N px (preserves aspect).
"$ATRIUM_CLI_PATH" capture screenshot CAP-381 --at 16 --max-edge 1280 --out /tmp/small.png

# Combine — crop, then shrink to fit your context budget.
"$ATRIUM_CLI_PATH" capture screenshot CAP-381 --at 16 --crop 1380,920,1150,900 --max-edge 800 --out /tmp/focused.png
```

This is the **primary** way to "look at" a moment as an agent. Correlate `--at` with timestamps from the transcript / events / chapters / annotations to grab "what was on screen when X happened." Combine `--crop` with annotation rects to extract exactly the region the user flagged. Use `--max-edge` to keep the PNG inside your budget (a retina frame is ~3 MB; at `--max-edge 1280` it's ~300 KB). Output path can be anywhere writable.

```bash
# 3. Slice a time range when you actually need motion (passthrough, no re-encode).
"$ATRIUM_CLI_PATH" capture chunk CAP-381 --start 9 --end 17 --out /tmp/cap381_9-17.mov

# 4. Enumerate / delete.
"$ATRIUM_CLI_PATH" capture list --json
"$ATRIUM_CLI_PATH" capture delete CAP-381 --yes
```

Use `chunk` for handing the user a focused excerpt to share, **not** for agent inspection — still frames carry more signal per token than video. `start` / `stop` / `flag` drive the live recorder when atrium is running.

## What NOT to do

- Don't `ffmpeg -ss … -frames:v 1` — `capture screenshot` does this without the dependency.
- Don't `ffprobe` for duration/dimensions — `capture show --json` gives durationMs + paths; the transcript + events tell you more about content than dimensions ever will.
- Don't decode the video yourself. To "see" second N, screenshot at N and crop around the annotation coords.
