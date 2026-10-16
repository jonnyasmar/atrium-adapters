# HTML pages in chat

Read this when a custom page is the best way to show something: a diagram, a flow, a timeline, a mockup, a custom chart, an animation — anything where full control of layout and drawing makes a better visual than canvas components. You write an HTML file, check it, publish it, and paste the short fence that publishing prints. The chat transcript then shows the page inline in the user's own theme, on the Mac and on the phone.

**Choosing the medium.** Pick whatever makes the best visual for this content; neither is the default. A ` ```canvas ` fence streams as you write and is native on every device: strong for metrics, standard bar and line graphs, tables, tabs, and anything that asks the user for input (choices, forms, values that come back to you). A page gives you full control: custom diagrams and charts, timelines, mockups, annotated layouts, animation. Use both in one reply when that helps. Either way, lean toward showing: when an answer has shape, a visual beats a paragraph.

**Where it renders:** agent chat panes (`agent-chat`), on desktop and the iPhone/iPad app. A terminal pane renders no markdown; there, make an HTML note instead (`notes-interactive-ui.md`).

**Requires a current atrium.** Run `"$ATRIUM_CLI_PATH" html --help` once. If the command doesn't exist, this atrium is too old: use a canvas instead.

## The flow

1. **Write** a self-contained file, e.g. `/tmp/build-times.html`.
2. **Check:** `"$ATRIUM_CLI_PATH" html preview /tmp/build-times.html`. It prints the screenshot path(s), the content height, console output and uncaught exceptions. **Look at the PNG with your image tool** before going on. Add `--theme light` (or `--theme dark`) to check the other theme if you used colour, and `--width 390` to check a phone width.
3. **Publish:** `"$ATRIUM_CLI_PATH" html publish /tmp/build-times.html --title "Build times by crate"`. Publishing refuses a page that throws an uncaught exception or never settles (a busy loop); fix it, or pass `--allow-errors` if the error is expected and harmless. stdout is the fence and nothing else; warnings go to stderr.
4. **Paste** the printed fence into your reply, exactly as printed:

````
```html render
{"v":1,"page":"3f9c…","title":"Build times by crate","heights":{"390":812,"600":640,"760":540,"960":500}}
```
````

Don't edit the fence and don't retype the hash: copy it. The page is stored by its hash; the fence only points at it.

**Don't restate the page.** The reader sees it right where the fence is. Write only what the page doesn't say: the conclusion, the caveat, the next step.

## Theme tokens

Every page gets atrium's theme as CSS custom properties, injected before your own CSS. Use them and the page matches whatever theme the user has, re-theming live when they switch. `"$ATRIUM_CLI_PATH" html tokens` prints this list with the current theme's values.

| Token | Use |
| --- | --- |
| `--text` | body text (already the default `color`) |
| `--text-muted` | secondary text, captions, axis labels |
| `--accent` | links, highlights, outlines, focus |
| `--accent-fill` + `--accent-foreground` | a solid accent button or badge and its label. Never put white text on raw `--accent` |
| `--surface` | a solid panel colour, rarely needed |
| `--tile` / `--tile-strong` | translucent card fills. **Use these for cards**: they stay right over wallpapers |
| `--border`, `--hairline` | borders; hairline for subtle dividers and grid lines |
| `--hover` | hover wash |
| `--success`, `--warning`, `--error` | status colours |
| `--chart-1` … `--chart-8` | eight distinct series colours, each readable on the background |
| `--bg` | the solid theme background. The page itself stays transparent; use `--bg` only where something must be opaque |
| `--font-sans`, `--font-mono` | the app's UI font and the user's code font |
| `--text-size` | the user's chat text size (already the default `font-size`) |
| `--radius`, `--radius-sm` | corner radii |

Defaults are at zero specificity: `html, body` have no margin, a transparent background, `color: var(--text)` and `font: var(--text-size)/1.5 var(--font-sans)`; links use `--accent`; `color-scheme` follows the theme, so form controls and `light-dark()` match. Any CSS you write wins over all of it, and setting a token on `html` or `:root` overrides it.

## Layout rules

- **Transparent page.** Don't paint `html`/`body`. The page sits on the chat's own surface.
- **Fluid width.** The page is shown at whatever width the chat column has, from about 360 px on a phone to about 1000 px. No fixed page widths, no horizontal scrolling. Use `max-width` plus percentages, flex or grid.
- **Fixed heights for charts.** Give SVG/canvas charts an explicit pixel height (`height: 240px`), not one derived from the viewport.
- **No `100vh` / `100dvh`.** The frame sizes itself to your content; viewport-relative heights have nothing sensible to resolve against.
- **No outer card or banner.** The transcript already frames the page with its title.
- **Self-contained is best.** Inline CSS and JS. The network is open, so a CDN script or font works, but the page renders without it on a slow connection only if you keep the essentials inline.
- **Local images:** reference them by absolute path (`<img src="/Users/me/chart.png">`) or relative to the HTML file; `publish` inlines them. Images over 2 MiB and non-image files are refused.
- **Size cap:** 4 MiB per page after inlining; titles up to 200 characters.

## Interaction

Pages can be interactive. On desktop the page shows as a snapshot until the user clicks it; then it runs live. On the phone, tapping the card opens it full screen.

- **Links:** ordinary `<a href="https://…">` links open in the user's browser. `window.open` does the same.
- **Send to the agent:** `atrium.send(payload)` (returns a Promise) sends `payload` back to you as a user turn, framed `[from inline chat artifact in pane <paneId>]` followed by the payload as JSON, the same envelope as a canvas submission. `atrium.send(payload, { framing: "Picked: {payload}" })` wraps it. It only works right after the user clicks or taps inside the page, and at most once every 2 seconds; a refused send rejects the Promise, so show "click to send" if you rely on it.
- No access to atrium itself: no `atrium://` commands, no files, no other panes.

## When it doesn't render

- **The command doesn't exist:** atrium is too old. Use a canvas.
- **"No renderer reachable" from `preview`:** no atrium desktop app is attached to this machine's daemon (a headless Linux box, or the app is closed). `publish` still works, but stores the page unchecked; check the page carefully yourself.
- **Shown as an HTML code block:** you wrote the HTML inline. Pages are never inline: publish, then paste the printed fence. A plain ` ```html ` block always stays a code sample.
- **"This page is no longer stored":** the fence's hash doesn't match a stored page, usually because the hash was retyped instead of copied. Publish again and paste the new fence.
- **Inline canvases and pages are switched off** in the user's Settings: it shows as code.
