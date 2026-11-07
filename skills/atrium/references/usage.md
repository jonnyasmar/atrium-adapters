# Usage queries, charts and boards

Use `"$ATRIUM_CLI_PATH" usage --help` first. This surface requires a build with
Usage enabled; it uses the same query service as the Usage pane. Queries read
local indexed records, not a provider's bill. `usage status` reports coverage,
backfill progress, scan measurements and the pricing version.

## Discover, query, explain

```bash
"$ATRIUM_CLI_PATH" usage schema --json
"$ATRIUM_CLI_PATH" usage schema --source spend --json
"$ATRIUM_CLI_PATH" usage status --json
"$ATRIUM_CLI_PATH" usage query --source spend --measure tokens --by model --range 30d --json
"$ATRIUM_CLI_PATH" usage query --source commits --measure agentCommits --by time --grain week --split model --json
"$ATRIUM_CLI_PATH" usage query --source turns --measure agentHours --by director --filter role=home,side,worker,routine --json
"$ATRIUM_CLI_PATH" usage ask 'tokens by model this week' --json
```

`schema` is the source of truth for sources, measures, supported dimensions,
aggregations, units, views, ranges and visualization fit. Source and measure names
are case-sensitive. A query flag `--by model` becomes `x: "dim:model"`;
`--grain week` implies `x: "time:week"`. Repeat `--filter dim=a,b` for multiple
filters. `--tz` accepts an IANA zone. Without one the daemon uses its host's zone.
The normal default range is `30d`; `--range` accepts `24h`, `7d`, `30d`, `90d`,
`1y`, `all`, `wtd`, `mtd`, or JSON `{"start":seconds,"end":seconds}` (end excluded).

`--spec` accepts inline JSON or `@file`, and replaces the query flags entirely.
Use it for views, formulas, comparison, normalization, sample thresholds and caps.
For example, save this as `query.json`, then run
`"$ATRIUM_CLI_PATH" usage query --spec @query.json --json`:

```json
{
  "v": 1,
  "measure": {
    "formula": "spend.apiValue / commits.agentCommits",
    "label": "API-equivalent value per agent commit",
    "unit": "usd",
    "minDen": 1
  },
  "x": "time:week",
  "range": "30d"
}
```

A view spec uses `view` instead of `source` and `measure`:

```json
{"v":1,"view":"recap","range":"7d"}
```

`ask` is a deterministic query suggestion: inspect its `spec`, `chips`,
`confidence` and preview `frame`. A `handoff: "agent"` or absent spec means you
must interpret the question, discover valid measures with `schema`, and run the
query yourself. Don't invent a result when the parser cannot answer a “why”.
Errors preserve the service's code and message, including ` (at /spec/measure)`
when it identifies a request path.

## Read the evidence with the number

Keep the returned frame intact. It carries the measure label, unit, bounds,
formula, estimates, source coverage and `provenance.asOf` (unix seconds).

- `estimate: true`, especially `spend.apiValue`, means an estimate of API-equivalent
  value, not an invoice or subscription payment.
- `null` means missing, suppressed or unavailable, never zero. An empty frame has
  an `empty.reason`; say what is missing rather than reporting no activity.
- Each `provenance.coverage` entry has a `status`: `ok`, `partial`, `missing` or `unsupported`.
  Preserve notes, skipped filters and stale/as-of information. An unsupported
  adapter cannot report usage; it did not necessarily do no work.
- `unit: "pct"` values are fractions. A normalized frame's `totalUnit` is the
  underlying unit for totals; don't format those counts or dollars as shares.
- Director keys are `<slug>@<homePaneId>`, not only a reusable slug. The `director`
  dimension rolls up attributed work; `role` distinguishes home, side, worker,
  routine, watched and none. Unknown attribution stays unknown.
- The helper is on demand. A first query can have partial coverage while backfill
  runs. Check `status` and retain the answer's as-of time.

## Snapshot in chat, live on a board

For an explanation in chat, run the query and put the **returned frame** in the
chart's `props.data`. Put the exact query in `props.query`. That snapshot keeps
the numbers your explanation refers to, and the query enables **Show live** and
**Pin to board**. Never synthesize numbers or discard provenance to shorten it.

For a deliberately live chart, replace `data` with
`{"$computed":"usage","args":<query spec>}`. It renders a skeleton while the
request is pending and refreshes as usage changes. This works in a chat fence,
a canvas note and a Usage board. Live canvas queries fill an omitted `tz` from
the viewing client's time zone; set it explicitly to preserve the same day
boundaries as a CLI query. The following is a complete live canvas spec;
use a `canvas` fence only when you intend live results:

```json
{
  "root": "tokens",
  "elements": {
    "tokens": {
      "type": "RankedBars",
      "props": {
        "title": "Tokens by model",
        "data": {
          "$computed": "usage",
          "args": {
            "v": 1,
            "source": "spend",
            "measure": "tokens",
            "x": "dim:model",
            "range": "30d"
          }
        }
      },
      "children": []
    }
  }
}
```

Pick the chart for the frame:

| Shape | Component |
|---|---|
| One scalar, delta, sparkline | `Kpi` |
| Time/category columns; additive splits | `BarChart` |
| Time trend | `LineChart` |
| Stacked time; model eras | `AreaChart` (`normalize: true` for eras) |
| Ranked categories | `RankedBars` |
| Ordinal categories, such as effort | `ColumnChart` |
| Any frame; category × split matrix | `DataTable`; `Pivot` |
| `clock`; `calendar` | `Heatmap`; `CalendarHeatmap` |
| `scatter`; `latency` or `versus` | `ScatterPlot`; `RangePlot` |
| `skyline`; `records`; `recap` | `Skyline`; `Records`; `Recap` |
| Live account limits or supplied quota windows | `Meter` (`source: "accounts"` or `windows`) |
| Board grid | `UsageBoard` with child layouts |

The components share `title`, `subtitle`, `query`, `height`, `legend` and `table`
props. Chart `height` accepts a positive number up to 1200 or `"fill"`.
`Meter` and `UsageBoard` have their own props. `AreaChart` uses `normalize`
and `labelsInBands`; there is no `eras` prop. Also normalize the query for shares
so its frame has `unit: "pct"` and `totalUnit`. Existing `BarGraph` and `LineGraph`
keep accepting their legacy rows. Mobile may show a chart as a table; preserve the
full frame so that fallback has the same evidence.

For this machine's live account limits, use `Meter` with `source: "accounts"`
and omit `windows`. Accounts are the default source when `windows` is absent;
`accounts` is the only accepted source value. Supply `windows` for explicit
quota values instead. Meter does not take a usage query as `data`.

## Boards and widgets

A **Usage board** is distinct from a task board or a director's dashboard note.
Use its id from `board list` or `board create`:

```bash
"$ATRIUM_CLI_PATH" usage board list --json
"$ATRIUM_CLI_PATH" usage board create 'Weekly review' --template weekly --json
"$ATRIUM_CLI_PATH" usage board show BOARD_ID --json
"$ATRIUM_CLI_PATH" usage board rename BOARD_ID 'My review'
"$ATRIUM_CLI_PATH" usage widget add --board BOARD_ID --id tokens --spec @query.json --viz table --title 'Usage' --size 6x4 --at 0,0
"$ATRIUM_CLI_PATH" usage widget list --board BOARD_ID --json
"$ATRIUM_CLI_PATH" usage widget update tokens --board BOARD_ID --title 'Usage this month'
"$ATRIUM_CLI_PATH" usage widget remove tokens --board BOARD_ID
"$ATRIUM_CLI_PATH" usage board export BOARD_ID --out board.json
"$ATRIUM_CLI_PATH" usage board import @board.json --name 'Review copy'
"$ATRIUM_CLI_PATH" usage board undo BOARD_ID
"$ATRIUM_CLI_PATH" usage board reset BOARD_ID
"$ATRIUM_CLI_PATH" usage board delete BOARD_ID
"$ATRIUM_CLI_PATH" usage open --board BOARD_ID
```

Templates: `overview`, `models`, `shipping`, `fleet`, `spend`, `directors`, `blank`,
`weekly`, `bakeoff`, `cost`. Reset is for template boards. Import creates a board
through the service; never write its storage files directly.

Widgets use `--viz number|bars|lines|area|eras|hbars|columns|table|pivot`. Add defaults
to a table and a 6×4 tile below existing widgets. `--size` is width×height on a
12-column grid; `--at` is column,row. Update changes only supplied fields; changing
visualization drops component-specific props that do not belong to the new type.
New widgets record the calling pane and agent as `addedBy`. Mutations are atomic
and revision-checked. On `stale_rev`, read the board again and reassess the edit;
don't blindly retry. `board export` without `--out` prints the complete JSON even
in human mode; `--json` otherwise preserves the service's camelCase data.

Board documents are versioned (`kind: "atrium.usage-board"`, `version: 1`), with a
`UsageBoard` root and a `layout: {x,y,w,h}` on every root child. Use the CLI for
board mutations, `note canvas-patch` for notes; those are different stores.

## Share

Sharing requires the desktop app and its share renderer. It can be unavailable
on a build without that renderer even when queries work:

```bash
"$ATRIUM_CLI_PATH" usage share BOARD_ID/WIDGET_ID --format square --theme paper --redact --out usage.png
"$ATRIUM_CLI_PATH" usage share --card shipped --range 7d --format x --theme ink --out shipped.png
```

Formats: `x`, `square`, `portrait`. Themes: `ink`, `paper`, `gold`. Cards: `shipped`,
`eras`, `fleet`, `clock`, `leverage`, `archetype`. `--redact` asks the renderer to
redact private labels. Creating an image does not publish or send it anywhere.
