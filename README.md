# Monday.com GraphQL Extractor

A Python tool that pulls data from a monday.com board via GraphQL and shapes it into a typed, Power BI-friendly table. It's designed to be run first as a quick way to inspect exactly what a board's data looks like, with the resulting logic then ported over to Power Query M — the GraphQL queries, pagination shape, and type-mapping tables are all written so that porting is close to mechanical rather than a redesign. See the module docstring in `monday_extract.py` for a line-by-line Python → M equivalence table.

## What it handles

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

## Setup

```powershell
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
```

Set your monday.com API key for the current terminal session only — never hardcode it:

```powershell
$env:MONDAY_API_KEY = "your-temp-key"
```

## Usage

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

- **Progress Tracking columns** (`progress` type): confirmed via monday's own API Playground that these return no value at all through `column_values`, under any combination of API version, explicit column ids, or `capabilities: [CALCULATED]` — for a leaf item or a parent with real subitems. Monday's own docs describe this value as calculated dynamically and only usable for filtering, not retrieval. The column is present in the schema but always comes through blank; see the `KNOWN GAP` comment in `parse_column_value` for the workaround that was scoped but not implemented (recompute the percentage client-side from the underlying Status rollup).
- **Team assignees on `people` columns** don't resolve to a name (only individual `person`-kind assignees do) — resolving a team would need a separate `teams()` query.
- **Classic subitems** (`fetch_subitems`) assume the subitems live on a separate hidden board; this path is intentionally left untouched by the multi-level work and should only be used on boards confirmed *not* to be multi-level (the script guards against this automatically — see `detect_board_mode`).

## Security notes

- The API key is only ever read from `MONDAY_API_KEY` and only ever placed in the `Authorization` header — never logged, printed, or written to disk.
- All dynamic values (board ids, column ids, cursors, user ids) are passed as GraphQL `variables`, never string-interpolated into query text — no query-injection surface.
- CSV output is sanitized against formula/CSV injection (OWASP-recognized risk for spreadsheet exports of user-editable text).
