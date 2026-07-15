# Monday.com GraphQL Extractor

Pulls data from a monday.com board via GraphQL and shapes it into a typed, Power BI-friendly table — one row per item, one column per board column, fully dynamic (no hardcoded column names). Two implementations, same behavior:

- **Power Query M** (`monday_extract_function.pq`) — the production path. Runs directly inside Power BI or Excel, no external tooling required. See [Power Query / Power BI usage](#power-query--power-bi-usage) below.
- **Python** (`monday_extract.py`) — a standalone inspection tool for previewing a board's data and schema from the command line before pulling it into Power BI, or for one-off CSV exports outside Power BI entirely.

A third file, `monday_extract.pq`, is the maintainable *source* the M version is generated from — a Power Query "section document" with each function as a separate, independently readable member. It's not directly usable in Power BI (Advanced Editor only accepts a single expression, not a multi-member document) and exists purely for development and review; `monday_extract_function.pq` is what you actually paste in.

## Power Query / Power BI usage

### 1. Create the API key parameter

In Power BI Desktop: **Home → Manage Parameters → New Parameter**.

| Field | Value |
|---|---|
| Name | `MondayApiKey` |
| Type | Text |
| Current Value | your monday.com API v2 token (**My Access Tokens** in your monday.com profile) |

### 2. Paste the extractor in as one query

**Get Data → Blank Query → Advanced Editor**, replace the placeholder with the entire contents of `monday_extract_function.pq`, then **Done**. Rename the query to `MondayExtract`.

It should show a function (**fx**) icon in the Queries pane — that confirms it registered correctly. It won't try to load anything itself; it's the shared pipeline every board query below calls into.

### 3. Pull a board

Add a new query whose entire content is a call to `MondayExtract`:

```
MondayExtract(148282, false)[table]
```

| Argument | Meaning |
|---|---|
| `148282` | the board id (visible in its URL) |
| `false` | `true` to pull that board's *classic* subitems instead of its main items; `false` for the normal case |
| `[table]` | selects the data table from the result |

Rename the query to something meaningful (e.g. `SalesBoard`) — it's ready to load as-is.

### 4. Repeat per board

Each call is fully independent, so pulling in a second, third, etc. board is just another copy of step 3 with a different board id — never anything to change in `MondayExtract` itself.

### Optional: the schema manifest

The output-column-to-M-type manifest (equivalent to the Python tool's `_schema.json`) is available per board too, via `[schema]` instead of `[table]`, wrapped in `Table.FromRecords`:

```
Table.FromRecords(MondayExtract(148282, false)[schema])
```

### First-run credential prompt

The first time a query actually calls the API, Power BI will ask how to authenticate to `api.monday.com` — choose **Anonymous**. The API key travels through a custom header inside the query itself, not through Web.Contents' built-in auth, so this is expected and correct.

## Python inspection tool

### What it handles

- **Fully dynamic** — no hardcoded column names anywhere. Every output field name comes from the board's own column titles at run time; renaming a column in monday.com is picked up automatically on the next run.
- **Three board modes, auto-detected where possible:**
  - Standard boards — main items only.
  - Standard boards — subitems (a separate hidden board with its own schema), via the `FETCH_SUBITEMS` switch.
  - **Multi-level boards** (monday's newer nested-subitems/rollup feature) — auto-detected and auto-flattened into one table with `Parent ID` and `Item Level` columns, no switch needed. A multi-level board can never accidentally be routed through the classic-subitems path, even if `FETCH_SUBITEMS` is left on.
- **Rollup column support** — Status, Timeline, Numbers, and Date columns on multi-level boards return nothing via the standard API fields unless `column_values(capabilities: [CALCULATED])` is requested; this is handled transparently, including translating a Status rollup's index/count breakdown back into readable labels via the column's own settings.
- **Per-type column parsing** for: text, numbers, checkbox, date, timeline, link, status, dropdown, people/person (with deactivated-user resolution), board_relation, dependency, formula, mirror, creation_log, last_updated, and file/item_id/subitems columns (deliberately dropped — not useful in a flat table).
- **Explicit typing throughout** — every output column is cast to a specific pandas dtype matching the exact Power Query M type it should become (`type text`, `type number`, `type date`, `Int64.Type`, etc.), rather than relying on pandas' own inference.
- **Schema manifest export** — alongside the CSV, a `_schema.json` file lists every output column with its monday source column, monday type, and target M type — the exact spec needed for `Table.TransformColumnTypes` when porting.
- **Power BI/Excel-safe CSV output** — UTF-8 BOM (so `£`-style characters don't get mangled by Excel's codepage guessing), embedded newlines collapsed (Excel's CSV parser is unreliable with multi-line cells), and formula-injection characters (`=`, `+`, `-`, `@`, tab) neutralized with a leading quote.

### Setup

```powershell
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
```

Set your monday.com API key for the current terminal session only — never hardcode it:

```powershell
$env:MONDAY_API_KEY = "your-temp-key"
```

### Usage

Edit the constants at the top of `monday_extract.py`:

| Constant | Purpose |
|---|---|
| `BOARD_ID` | The monday.com board to pull. |
| `FETCH_SUBITEMS` | `True` to pull a *classic* board's subitems instead of its main items. Has no effect on multi-level boards (they auto-flatten regardless). |
| `DEBUG` | `True` to print the full column list, resulting dtypes, and a data preview — useful while investigating a new board's schema. Off by default to keep routine runs to a short summary. |
| `API_VERSION` | Pinned monday API version. Bump if monday exposes new column features that need a newer version. |

Then run:

```powershell
.venv\Scripts\python.exe monday_extract.py
```

Output lands in `output/`:
- `board_<id>.csv` — the data, UTF-8 BOM, one row per item.
- `board_<id>_schema.json` — the output-column-to-M-type manifest.

## Known limitations

Shared by both implementations (each has a version of this note in its own header/docstring):

- **Progress Tracking columns** (`progress` type) never return a usable value through `column_values`, under any combination of API version, explicit column ids, or `capabilities: [CALCULATED]` — for a leaf item or a parent with real subitems. Monday's own docs describe this value as calculated dynamically and only usable for filtering, not retrieval. The column is present in the schema but always comes through blank; recomputing it client-side from the underlying Status rollup would be possible but isn't implemented.
- **Team assignees on `people` columns** don't resolve to a name (only individual `person`-kind assignees do) — resolving a team would need a separate `teams()` query.
- **Classic subitems** assume the subitems live on a separate hidden board; this path is intentionally left untouched by the multi-level work and should only be used on boards confirmed *not* to be multi-level (both implementations guard against this automatically — Python's `detect_board_mode`, M's `DetectBoardMode`).

## Security notes

- **Python**: the API key is only ever read from `MONDAY_API_KEY` and only ever placed in the `Authorization` header — never logged, printed, or written to disk.
- **Power Query**: the `MondayApiKey` parameter is a Power BI Parameter, not a secrets store — its value is saved as recoverable metadata inside the .pbix (and inside the published dataset, if you publish it). Never commit or share a .pbix with the real key filled in; leave the parameter blank in anything that goes to source control or a shared drive, and set the real value locally after opening. If publishing to the Power BI Service, prefer setting the real value via that dataset's **Settings → Parameters** in the Service over baking it into the uploaded file — that scopes exposure to workspace Edit/Admin rights rather than "whoever has the file."
- Both implementations pass all dynamic values (board ids, column ids, cursors, user ids) as GraphQL variables, never string-interpolated into query text — no query-injection surface.
- The Python tool's CSV output is additionally sanitized against formula/CSV injection (OWASP-recognized risk for spreadsheet exports of user-editable text) — not applicable to the Power Query version, which reads straight from the GraphQL JSON into the Power BI model.
