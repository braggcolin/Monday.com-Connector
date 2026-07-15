"""
Inspect a monday.com board via the GraphQL API and shape it into a
Power BI-friendly table (one row per item, one column per board column,
with types resolved from monday's column `type` metadata).

Everything here goes through the single monday.com GraphQL endpoint
(no REST calls anywhere) so it has a direct M equivalent:

    Python                              Power Query M
    ----------------------------------  -----------------------------------
    requests.post(API_URL, ...)         Web.Contents(url, [Headers=..., Content=...])
    response.json()                     Json.Document(...)
    fetch_next_page() loop              List.Generate(initial, condition, next, selector)
    fetch_board_metadata() then         two sequential Web.Contents calls: first gets
      fetch_first_page(..., columnIds)  `columns` alone, second passes those ids into
                                         column_values(ids: ..., capabilities: [CALCULATED])
                                         (the capabilities argument is required for
                                         rollup-capable columns — see below)
    resolve_output_names()              a name-mapping table, merged in before pivot
    build_dataframe() row assembly      Table.ExpandListColumn / Table.Pivot
    MONDAY_TYPE_TO_M_TYPES map          the exact args to Table.TransformColumnTypes
    fetch_users() + merge               a second Web.Contents call + Table.NestedJoin
    FETCH_SUBITEMS (bool)               an M query parameter of type Logical, branching
                                         between the two query paths (if FetchSubitems then ...)
    detect_board_mode()                 a data-driven if/then (compares a subitem's own
                                         board.id to the parent board's id) — NOT a query
                                         parameter like FETCH_SUBITEMS; this branch is
                                         automatic based on what the API returns
    fetch_multi_tier_descendants()      a second Web.Contents call per batch of top-level
                                         item ids, merged into the main items table
                                         (List.Generate over batches, then Table.Combine)
    compute_item_levels()               a recursive function walking ParentID chains
                                         (M supports `let Level = (id) => ... @Level ... in`
                                         self-referencing recursion)
    get_status_labels() + BatteryValue  a lookup table built from each status column's
      branch in parse_column_value      settings_str (label index -> label text), then
                                         Table.NestedJoin against each item's battery_value
                                         (index/count pairs) to render readable text

This is throwaway inspection code, but the GraphQL queries, the pagination
shape, and the type map are written to be copied over as-is.

Auth: set the MONDAY_API_KEY environment variable before running.
Do NOT hardcode the key in this file.

    PowerShell (current session only):
        $env:MONDAY_API_KEY = "key-goes-here"
        .venv\\Scripts\\python.exe monday_extract.py
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any

import pandas as pd
import requests

API_URL = "https://api.monday.com/v2"
API_VERSION = "2026-07"  # current version at time of writing; kept in sync
# with monday's own API Playground. NOTE: the earlier "some columns are
# missing" bug turned out to be unrelated to this — see COLUMN_VALUES_FIELDS
# and the two-phase fetch below for the actual cause/fix.
BOARD_ID = 18418746285

# When True, pull this board's SUBITEMS instead of its main items. Subitems
# live on monday's auto-created, separate "subitems board" with its own
# column schema — a different query path entirely, not a filter. This is
# deliberately a plain top-level boolean so it maps 1:1 onto an M query
# parameter of type Logical (a "FetchSubitems" parameter branching the query).
FETCH_SUBITEMS: bool = False

# When True, prints the full column list, resulting dtypes, and a data
# preview — useful while investigating a new board's schema. Off by default:
# a routine run only needs the short summary (mode, row count, output paths),
# and the dtypes/preview dump otherwise echoes real board data (names,
# emails, etc.) to the console for no operational reason.
DEBUG: bool = False

# Single source of truth for the final column typing. Used here to build the
# schema manifest (output/board_<id>_schema.json); in M this becomes the
# {name, type} pairs passed straight into Table.TransformColumnTypes.
# Lists line up positionally with MULTI_VALUE_SUFFIXES below (e.g. "link" ->
# [URL type, DisplayName type]). Types not listed fall back to ["type text"].
MONDAY_TYPE_TO_M_TYPES: dict[str, list[str]] = {
    "numbers": ["type number"],
    "checkbox": ["type logical"],
    "date": ["type datetime"],
    "timeline": ["type date", "type date"],
    "link": ["type text", "type text"],
    "creation_log": ["type text", "type text", "type datetime"],
    "last_updated": ["type text", "type text", "type datetime"],
    # BoardID/ItemID kept as text (not Int64) since a board_relation column
    # can link to more than one item — multiple ids get "; "-joined.
    "board_relation": ["type text", "type text", "type text"],
    "people": ["type text", "type text"],
    "person": ["type text", "type text"],
    # dependencies link to items on the SAME board, so no BoardID needed.
    "dependency": ["type text", "type text"],
}

# Columns whose value is split into multiple output fields, and the name
# suffixes to use for each (applied to the column's display title).
MULTI_VALUE_SUFFIXES: dict[str, list[str]] = {
    "timeline": ["_Start", "_End"],
    "link": ["_URL", "_DisplayName"],
    "creation_log": ["_User", "_Email", "_DateTime"],
    "last_updated": ["_User", "_Email", "_DateTime"],
    "board_relation": ["_DisplayName", "_BoardID", "_ItemID"],
    "people": ["_Name", "_Email"],
    "person": ["_Name", "_Email"],
    "dependency": ["_DisplayName", "_ItemID"],
}

# item_id: monday's built-in "Item ID" column just redisplays item.id, which
# we already emit as our own item_id field — omit it to avoid a duplicate.
# file: asset/attachment columns (binary files, not tabular data) — not
# Power BI-friendly, drop entirely.
# name: the item-name pseudo-column; it never appears in column_values (item
# name is a top-level item field, not a real column), and is handled
# separately via get_item_name_field() so its *title* becomes our item-name
# output field instead of a hardcoded "item_name".
# subtasks: the built-in "Subitems" preview column that auto-appears on any
# board with subitems enabled — now redundant since FETCH_SUBITEMS pulls
# subitems properly (with their own schema) as a separate run.
SKIP_COLUMN_TYPES = {"item_id", "file", "name", "subtasks"}

# Explicit pandas dtype per M type, applied to every output column after
# assembly. Without this, an all-null column (e.g. a URL field nobody filled
# in yet) has nothing for pandas to infer a dtype from and silently falls
# back to generic "object" — casting explicitly avoids that ambiguity and
# keeps local dtypes in lockstep with what M will enforce.
M_TYPE_TO_PANDAS_DTYPE: dict[str, str] = {
    "type text": "string",
    "type number": "float64",
    "type logical": "boolean",
    "type datetime": "datetime64[ns]",
    "type date": "datetime64[ns]",
    "Int64.Type": "Int64",
}

# board_relation, formula, mirror, and dependency columns often return empty
# text/value in the generic ColumnValue fields — monday's recommended way to
# read them is via their typed inline fragments instead.
#
# NumbersValue/DateValue/TimelineValue/BatteryValue are for multi-level board
# ROLLUP columns specifically: confirmed via monday's docs
# (https://developer.monday.com/api-reference/docs/working-with-multi-level-boards)
# that column_values for a rollup-capable column returns nothing at all —
# not even for a leaf item with a directly-set, non-calculated value — unless
# the column_values(capabilities: [CALCULATED]) argument is passed (see where
# this is used below). `is_leaf` distinguishes a static value (true) from one
# calculated/rolled-up from children (false). Status rollups resolve to
# BatteryValue (a per-child-status-label count breakdown), not a plain label.
COLUMN_VALUES_FIELDS = """
        id
        type
        text
        value
        ... on BoardRelationValue {
          linked_item_ids
          linked_items {
            id
            name
          }
        }
        ... on FormulaValue {
          display_value
        }
        ... on PeopleValue {
          persons_and_teams {
            id
            kind
          }
        }
        ... on MirrorValue {
          display_value
        }
        ... on DependencyValue {
          linked_item_ids
          linked_items {
            id
            name
          }
        }
        ... on NumbersValue {
          number
          is_leaf
        }
        ... on DateValue {
          date
          is_leaf
        }
        ... on TimelineValue {
          from
          to
          is_leaf
        }
        ... on BatteryValue {
          battery_value {
            key
            count
          }
          is_leaf
        }
"""

# Minimal probe used to auto-detect a board's subitems shape, without paying
# for full column_values on every item's subitems. Compared against the
# parent board's own id in detect_board_mode(): same id -> monday's newer
# multi-tier feature (subitems share the parent board, same schema all the
# way down); different id -> classic subitems (separate hidden board,
# unrelated to this — that path is untouched and still driven by
# FETCH_SUBITEMS). No subitems at all -> plain board, also untouched.
SUBITEMS_PROBE_FIELD = """
        subitems {
          id
          board {
            id
          }
        }
"""

# Split into two phases (metadata first, then items): column_values(ids:...)
# is more efficient than relying on the implicit "return everything" default,
# and is required alongside capabilities: [CALCULATED] below (see
# COLUMN_VALUES_FIELDS) to retrieve values for rollup-capable columns on
# multi-level boards — confirmed via monday's docs that those return nothing
# at all, even for a leaf item's own static value, without that argument.
BOARD_METADATA_QUERY = """
query ($boardId: [ID!]) {
  boards(ids: $boardId) {
    id
    name
    item_terminology
    columns {
      id
      title
      type
      settings_str
    }
  }
}
"""

FIRST_ITEMS_PAGE_QUERY = f"""
query ($boardId: [ID!], $columnIds: [String!]) {{
  boards(ids: $boardId) {{
    items_page(limit: 100) {{
      cursor
      items {{
        id
        name
        group {{
          id
          title
        }}
{SUBITEMS_PROBE_FIELD}
        column_values(ids: $columnIds, capabilities: [CALCULATED]) {{
{COLUMN_VALUES_FIELDS}
        }}
      }}
    }}
  }}
}}
"""

NEXT_ITEMS_QUERY = f"""
query ($cursor: String!, $columnIds: [String!]) {{
  next_items_page(limit: 100, cursor: $cursor) {{
    cursor
    items {{
      id
      name
      group {{
        id
        title
      }}
{SUBITEMS_PROBE_FIELD}
      column_values(ids: $columnIds, capabilities: [CALCULATED]) {{
{COLUMN_VALUES_FIELDS}
      }}
    }}
  }}
}}
"""

# Fields for a subitem: its own id/name (a subitem is a full Item), the
# parent item's id (-> our "Parent ID" output field), the subitems board's
# own metadata (fetched from here since a plain top-level `boards(ids:...)`
# query can't target monday's auto-created subitems board directly — its id
# isn't known ahead of time), and its column_values via the same typed fields
# used for main items.
SUBITEM_FIELDS = (
    """
          id
          name
          group {
            id
            title
          }
          parent_item {
            id
          }
          board {
            id
            name
            item_terminology
            columns {
              id
              title
              type
              settings_str
            }
          }
          column_values {
"""
    + COLUMN_VALUES_FIELDS
    + """
          }
"""
)

SUBITEMS_BOARD_QUERY = f"""
query ($boardId: [ID!]) {{
  boards(ids: $boardId) {{
    id
    name
    items_page(limit: 100) {{
      cursor
      items {{
        id
        subitems {{
{SUBITEM_FIELDS}
        }}
      }}
    }}
  }}
}}
"""

SUBITEMS_NEXT_ITEMS_QUERY = f"""
query ($cursor: String!) {{
  next_items_page(limit: 100, cursor: $cursor) {{
    cursor
    items {{
      id
      subitems {{
{SUBITEM_FIELDS}
      }}
    }}
  }}
}}
"""

USERS_QUERY = """
query ($userIds: [ID!]) {
  users(ids: $userIds, status: [ACTIVE, INACTIVE, PENDING]) {
    id
    name
    email
  }
}
"""
# status defaults to [ACTIVE, PENDING] — deactivated/removed users (common on
# older items, e.g. someone assigned a task years ago who's since left) are
# silently excluded otherwise, and parse_column_value falls back to the bare
# numeric id when a person can't be resolved.

# Multi-tier boards: a single non-recursive `subitems` call on a top-level
# item already returns its FULL transitive descendant closure (confirmed
# empirically — monday flattens the whole subtree into one array, each entry
# carrying its own correct parent_item.id), so unlike SUBITEM_FIELDS above
# this deliberately does NOT nest `subitems` inside itself.
MULTI_TIER_SUBITEMS_QUERY = f"""
query ($itemIds: [ID!], $columnIds: [String!]) {{
  items(ids: $itemIds) {{
    id
    subitems {{
      id
      name
      group {{
        id
        title
      }}
      parent_item {{
        id
      }}
      column_values(ids: $columnIds, capabilities: [CALCULATED]) {{
{COLUMN_VALUES_FIELDS}
      }}
    }}
  }}
}}
"""


def get_api_key() -> str:
    key = os.environ.get("MONDAY_API_KEY")
    if not key:
        sys.exit(
            "MONDAY_API_KEY is not set. In PowerShell run:\n"
            '  $env:MONDAY_API_KEY = "your-temp-key"\n'
            "then re-run this script."
        )
    return key


def run_query(query: str, variables: dict[str, Any], api_key: str) -> dict[str, Any]:
    response = requests.post(
        API_URL,
        json={"query": query, "variables": variables},
        headers={
            "Authorization": api_key,
            "API-Version": API_VERSION,
        },
        timeout=30,
    )
    response.raise_for_status()
    payload = response.json()
    if "errors" in payload:
        raise RuntimeError(json.dumps(payload["errors"], indent=2))
    return payload["data"]


def fetch_board_metadata(board_id: int, api_key: str) -> tuple[dict, list[dict]]:
    """One GraphQL call: board metadata + columns only — no items yet, since
    we need the column ids first to request column_values(ids: [...]) explicitly.
    """
    data = run_query(BOARD_METADATA_QUERY, {"boardId": [str(board_id)]}, api_key)
    boards = data["boards"]
    if not boards:
        sys.exit(f"No board found with id {board_id} (check the key has access to it).")
    board = boards[0]
    return board, board["columns"]


def fetch_first_page(board_id: int, column_ids: list[str], api_key: str) -> dict:
    """One GraphQL call: the first items_page, with column_values scoped to
    the given column ids (see BOARD_METADATA_QUERY docstring for why).
    """
    data = run_query(
        FIRST_ITEMS_PAGE_QUERY,
        {"boardId": [str(board_id)], "columnIds": column_ids},
        api_key,
    )
    boards = data["boards"]
    if not boards:
        sys.exit(f"No board found with id {board_id} (check the key has access to it).")
    return boards[0]["items_page"]


def fetch_next_page(cursor: str, column_ids: list[str], api_key: str) -> dict:
    """One GraphQL call: the next items_page for a given cursor."""
    data = run_query(
        NEXT_ITEMS_QUERY, {"cursor": cursor, "columnIds": column_ids}, api_key
    )
    return data["next_items_page"]


def fetch_board(board_id: int, api_key: str) -> tuple[dict, list[dict], list[dict]]:
    """Returns (board_meta, columns, items) with pagination followed.

    This loop is the List.Generate(initial, condition, next, selector) shape:
      initial   = fetch_first_page(board_id, column_ids)
      condition = page.cursor <> null
      next      = fetch_next_page(page.cursor, column_ids)
      selector  = page.items
    """
    board, columns = fetch_board_metadata(board_id, api_key)
    column_ids = [c["id"] for c in columns]

    page = fetch_first_page(board_id, column_ids, api_key)
    items = list(page["items"])
    cursor = page["cursor"]

    while cursor:
        page = fetch_next_page(cursor, column_ids, api_key)
        items.extend(page["items"])
        cursor = page["cursor"]

    return board, columns, items


def fetch_subitems(board_id: int, api_key: str) -> tuple[dict, list[dict], list[dict]]:
    """Returns (subitems_board_meta, subitems_board_columns, subitems) — same
    shape as fetch_board(), so it flows through the exact same downstream
    pipeline (build_dataframe, apply_output_dtypes, etc).

    Pagination still walks the PARENT board's items_page/next_items_page
    (List.Generate shape, same as fetch_board); subitems are nested inside
    each parent item and flattened out here. The subitems board's own
    metadata (name, item_terminology, columns) is read off the first subitem
    encountered, since monday's shared subitems board doesn't have a
    globally-known id you can query directly ahead of time.
    """
    data = run_query(SUBITEMS_BOARD_QUERY, {"boardId": [str(board_id)]}, api_key)
    boards = data["boards"]
    if not boards:
        sys.exit(f"No board found with id {board_id} (check the key has access to it).")
    items_page = boards[0]["items_page"]
    parent_items = list(items_page["items"])
    cursor = items_page["cursor"]

    while cursor:
        data = run_query(SUBITEMS_NEXT_ITEMS_QUERY, {"cursor": cursor}, api_key)
        page = data["next_items_page"]
        parent_items.extend(page["items"])
        cursor = page["cursor"]

    subitems = [
        sub for parent in parent_items for sub in (parent.get("subitems") or [])
    ]
    if not subitems:
        sys.exit(
            f"No subitems found on board {board_id} (or none of its items have subitems)."
        )

    subitems_board = subitems[0]["board"]
    return subitems_board, subitems_board["columns"], subitems


def detect_board_mode(board_id: int, items: list[dict]) -> str:
    """Classifies a board's subitems shape from the lightweight
    SUBITEMS_PROBE_FIELD already present on each item, without any extra
    GraphQL call:

      "none"       — no item has subitems.
      "classic"    — subitems exist and live on a DIFFERENT board (monday's
                     older single-level subitems, auto-created separate
                     board) — unrelated to this, still driven by
                     FETCH_SUBITEMS and completely untouched here.
      "multi_tier" — subitems exist and live on the SAME board as their
                     parent — monday's newer nested-subitems feature, which
                     this module auto-flattens (see fetch_multi_tier_descendants).
    """
    for item in items:
        subs = item.get("subitems") or []
        if subs:
            sub_board_id = (subs[0].get("board") or {}).get("id")
            return "multi_tier" if str(sub_board_id) == str(board_id) else "classic"
    return "none"


def fetch_multi_tier_descendants(
    top_level_item_ids: list[str], column_ids: list[str], api_key: str
) -> list[dict]:
    """For multi-tier boards, a single non-recursive `subitems` call per item
    already returns its full transitive descendant closure — monday flattens
    the whole subtree into one array, each entry carrying its own correct
    parent_item.id — so no recursive nesting is needed; this just batches
    that call across the given top-level item ids.
    """
    descendants: list[dict] = []
    seen_ids: set[str] = set()
    batch_size = 25
    for i in range(0, len(top_level_item_ids), batch_size):
        batch = top_level_item_ids[i : i + batch_size]
        data = run_query(
            MULTI_TIER_SUBITEMS_QUERY,
            {"itemIds": batch, "columnIds": column_ids},
            api_key,
        )
        for item in data.get("items") or []:
            for sub in item.get("subitems") or []:
                if (
                    sub["id"] not in seen_ids
                ):  # cheap insurance; branches shouldn't overlap
                    seen_ids.add(sub["id"])
                    descendants.append(sub)
    return descendants


def compute_item_levels(items: list[dict]) -> dict[str, int]:
    """Depth of each item in the tree, walked from parent_item chains: a
    top-level item (no parent) is level 1, everything else is its parent's
    level + 1.
    """
    parent_by_id = {
        item["id"]: (item.get("parent_item") or {}).get("id") for item in items
    }
    levels: dict[str, int] = {}

    def level_of(item_id: str, chain: set[str]) -> int:
        if item_id in levels:
            return levels[item_id]
        if item_id in chain:
            raise ValueError(f"Cycle detected in parent_item chain at item {item_id}")
        parent_id = parent_by_id.get(item_id)
        levels[item_id] = (
            1 if not parent_id else level_of(parent_id, chain | {item_id}) + 1
        )
        return levels[item_id]

    for item in items:
        level_of(item["id"], set())
    return levels


def fetch_users(user_ids: set[str], api_key: str) -> dict[str, dict]:
    """One GraphQL call resolving user ids -> {id, name, email}.

    Needed because creation_log/last_updated column_values only carry a user
    id, not the display name or email — this is a second fetch + join, same
    shape as fetch_board's, and ports to M as a second Web.Contents call
    merged in with Table.NestedJoin.
    """
    if not user_ids:
        return {}
    data = run_query(USERS_QUERY, {"userIds": sorted(user_ids)}, api_key)
    return {u["id"]: u for u in data["users"]}


def parse_user_log_value(raw_value: str | None) -> tuple[str | None, Any]:
    """Extract (user_id, raw_timestamp) from a creation_log/last_updated value.

    Confirmed shape from a live board: {"created_at": "...Z", "creator_id": "..."}
    for creation_log. last_updated hasn't been confirmed yet, so a few likely
    key variants are kept as fallbacks — if none match, the raw JSON is
    printed to stderr so we can add the right key.
    """
    if not raw_value or raw_value == "null":
        return None, None
    parsed = json.loads(raw_value)
    user_id = (
        parsed.get("creator_id")
        or parsed.get("updater_id")
        or parsed.get("changer_id")
        or parsed.get("user_id")
    )
    timestamp = (
        parsed.get("created_at") or parsed.get("updated_at") or parsed.get("changed_at")
    )
    if user_id is None or timestamp is None:
        print(
            f"WARN: unrecognized creation_log/last_updated value shape: {raw_value}",
            file=sys.stderr,
        )
    return (str(user_id) if user_id is not None else None), timestamp


def parse_log_timestamp(raw_timestamp: Any) -> Any:
    if raw_timestamp is None:
        return None
    if isinstance(raw_timestamp, (int, float)) or (
        isinstance(raw_timestamp, str) and raw_timestamp.isdigit()
    ):
        return pd.to_datetime(int(raw_timestamp), unit="ms", errors="coerce")
    return pd.to_datetime(raw_timestamp, errors="coerce")


def parse_board_relation_settings(settings_str: str | None) -> str | None:
    """Extract "; "-joined connected board ids from a board_relation column's
    settings_str. This is column *configuration* (which board(s) it can link
    to), identical for every item, so it's parsed once per column here rather
    than guessed at from each item's value JSON.
    """
    if not settings_str or settings_str == "null":
        return None
    parsed = json.loads(settings_str)
    board_ids = [str(b) for b in (parsed.get("boardIds") or []) if b is not None]
    if not board_ids:
        print(
            f"WARN: unrecognized board_relation column settings shape: {settings_str}",
            file=sys.stderr,
        )
        return None
    return "; ".join(dict.fromkeys(board_ids))  # dedupe, keep order


def get_board_relation_board_ids(columns: list[dict]) -> dict[str, str | None]:
    """column id -> "; "-joined connected board id(s), for board_relation columns."""
    return {
        c["id"]: parse_board_relation_settings(c.get("settings_str"))
        for c in columns
        if c["type"] == "board_relation"
    }


def parse_status_labels(settings_str: str | None) -> dict[str, str]:
    """Extract {label index -> label text} from a status column's settings_str
    (e.g. {"labels": {"0": "Done", "1": "Working on it"}}). Needed to turn a
    rollup Status column's BatteryValue (index/count pairs) back into
    readable text, since BatteryValue only carries the index, not the label.
    """
    if not settings_str or settings_str == "null":
        return {}
    parsed = json.loads(settings_str)
    return {str(k): v for k, v in (parsed.get("labels") or {}).items()}


def get_status_labels(columns: list[dict]) -> dict[str, dict[str, str]]:
    """column id -> {label index -> label text}, for status columns."""
    return {
        c["id"]: parse_status_labels(c.get("settings_str"))
        for c in columns
        if c["type"] == "status"
    }


def get_item_name_field(
    columns: list[dict], item_terminology: str | None = None
) -> str:
    """The display label for the item-name field, using the same precedence
    the monday UI uses for that column's header:

      1. board.item_terminology — boards can rename what an "item" is called
         (e.g. "Action", "Task", "Deal"); this is what the UI actually shows
         as the leftmost column header when set.
      2. the "name"-type pseudo-column's title — falls back to this if a
         board hasn't customized item_terminology (it's usually just "Name").
      3. "item_name" if neither is available.
    """
    if item_terminology:
        return item_terminology
    for col in columns:
        if col["type"] == "name":
            return col["title"]
    return "item_name"


def linked_items_display_and_ids(
    linked_items: list[dict], fallback_text: str | None
) -> tuple[str | None, str | None]:
    """Shared by board_relation and dependency: both resolve to the same
    `linked_items { id name }` shape and both need "; "-joined display names
    and ids (a column can link to more than one item).
    """
    display_name = (
        "; ".join(li["name"] for li in linked_items if li.get("name")) or fallback_text
    )
    item_id_str = (
        "; ".join(str(li["id"]) for li in linked_items if li.get("id")) or None
    )
    return display_name, item_id_str


def parse_column_value(
    col_type: str,
    cv: dict,
    user_lookup: dict[str, dict] | None = None,
    board_relation_board_ids: dict[str, str | None] | None = None,
    status_labels: dict[str, dict[str, str]] | None = None,
) -> Any:
    """Map a monday.com column_value to a plain Python value based on its type.

    Each branch below owns its own empty-value handling (empty text/value both
    valid inputs) so that multi-value types (link/timeline/creation_log/
    last_updated/board_relation) always return a same-shaped tuple, never a
    bare None.
    """
    text = cv.get("text")
    raw_value = cv.get("value")

    if col_type == "numbers":
        # NumbersValue.number is how rollup-capable Numbers columns on
        # multi-level boards return their value (plain text/value come back
        # empty for those) — see COLUMN_VALUES_FIELDS. Falls back to text for
        # ordinary, non-rollup Numbers columns.
        if cv.get("number") is not None:
            return cv["number"]
        return pd.to_numeric(text, errors="coerce") if text else None

    if col_type == "checkbox":
        if raw_value and raw_value != "null":
            checked = json.loads(raw_value).get("checked")
            # monday has returned this both as a JSON bool and as the string
            # "true" across API versions/column configs — handle either.
            return checked is True or (
                isinstance(checked, str) and checked.lower() == "true"
            )
        return False

    if col_type == "date":
        if raw_value and raw_value != "null":
            parsed = json.loads(raw_value)
            date_part = parsed.get("date")
            time_part = parsed.get("time")
            if date_part and time_part:
                return pd.to_datetime(f"{date_part} {time_part}", errors="coerce")
            if date_part:
                return pd.to_datetime(date_part, errors="coerce")
        return None

    if col_type == "timeline":
        start, end = None, None
        # TimelineValue.from/to is how rollup-capable Timeline columns on
        # multi-level boards return their value — see COLUMN_VALUES_FIELDS.
        if cv.get("from") is not None or cv.get("to") is not None:
            start = pd.to_datetime(cv.get("from"), errors="coerce")
            end = pd.to_datetime(cv.get("to"), errors="coerce")
        elif raw_value and raw_value != "null":
            parsed = json.loads(raw_value)
            start = pd.to_datetime(parsed.get("from"), errors="coerce")
            end = pd.to_datetime(parsed.get("to"), errors="coerce")
        elif text:
            # fallback: monday renders text as "MM/DD/YYYY - MM/DD/YYYY"
            parts = [p.strip() for p in text.split(" - ")]
            if len(parts) == 2:
                start = pd.to_datetime(parts[0], errors="coerce")
                end = pd.to_datetime(parts[1], errors="coerce")
        return start, end

    if col_type == "link":
        if raw_value and raw_value != "null":
            parsed = json.loads(raw_value)
            return parsed.get("url"), parsed.get("text")
        return None, text

    if col_type == "board_relation":
        display_name, item_id_str = linked_items_display_and_ids(
            cv.get("linked_items") or [], text
        )
        board_id_str = (board_relation_board_ids or {}).get(cv["id"])
        return display_name, board_id_str, item_id_str

    if col_type in ("creation_log", "last_updated"):
        user_id, ts_raw = parse_user_log_value(raw_value)
        user = (user_lookup or {}).get(user_id, {}) if user_id else {}
        return user.get("name"), user.get("email"), parse_log_timestamp(ts_raw)

    if col_type == "formula":
        # the computed result, not the formula definition — plain text is fine.
        return cv.get("display_value") or text

    if col_type == "mirror":
        # deliberately plain text, not the mirrored column's real type — if
        # someone needs it properly typed, pull both boards and relate them.
        return cv.get("display_value") or text

    if col_type == "dependency":
        return linked_items_display_and_ids(cv.get("linked_items") or [], text)

    if col_type in ("people", "person"):
        assignees = cv.get("persons_and_teams") or []
        names, emails = [], []
        for a in assignees:
            if a.get("kind") != "person":
                continue  # teams have no email to resolve; text already covers the name
            user = (user_lookup or {}).get(str(a["id"]), {})
            names.append(user.get("name") or str(a["id"]))
            if user.get("email"):
                emails.append(user["email"])
        display_name = "; ".join(names) or text
        email_str = "; ".join(emails) or None
        return display_name, email_str

    if col_type == "status":
        # BatteryValue is how a rollup-capable Status column on a multi-level
        # board returns its value (plain text comes back empty for those) —
        # see COLUMN_VALUES_FIELDS. It's a label-index/count breakdown (a
        # single leaf item's own status is just one index with count=1), not
        # a plain label, so it needs translating via the column's own
        # settings_str label map. Falls back to text for ordinary Status columns.
        battery = cv.get("battery_value")
        if battery:
            labels = (status_labels or {}).get(cv["id"], {})
            single_entry = (
                len(battery) == 1
            )  # a leaf's own status: count is redundant noise
            parts = []
            for entry in battery:
                label = labels.get(str(entry.get("key")), str(entry.get("key")))
                parts.append(
                    label if single_entry else f"{label} ({entry.get('count')})"
                )
            return "; ".join(parts) or text
        return text

    # dropdown, email, phone, long_text, text, etc.
    # `text` is monday's own human-readable rendering — good enough for inspection.
    #
    # KNOWN GAP - "progress" (Progress Tracking column): confirmed via the
    # Playground that text/value are empty even with capabilities:[CALCULATED],
    # for both a leaf item and a parent with real subitems. Monday's own docs
    # note its value "is typically null because its percentage is calculated
    # dynamically" — it appears to only be usable for filtering
    # (items_page rules with compare_value thresholds like "50"), not
    # retrievable as a plain value at all. A workaround would mean reading the
    # column's settings_str for which status column(s)/labels it tracks and
    # computing the percentage ourselves from that Status column's rollup
    # data — parked, not implemented, per user decision (2026-07).
    return text


def resolve_output_names(
    columns: list[dict],
    item_terminology: str | None = None,
    include_parent_id: bool = False,
    include_item_level: bool = False,
) -> dict[str, list[str]]:
    """Map each column id to its output field name(s), using display titles
    (not monday's internal ids) and de-duplicating collisions with _2, _3, ...

    Columns listed in MULTI_VALUE_SUFFIXES produce multiple names (e.g.
    timeline -> "<Title>_Start"/"<Title>_End"). Columns in SKIP_COLUMN_TYPES
    (monday's built-in "Item ID" column) produce no output name at all.
    """
    used_names: set[str] = {
        "item_id",
        get_item_name_field(columns, item_terminology),
        "Group",
    }
    if include_parent_id:
        used_names.add("Parent ID")
    if include_item_level:
        used_names.add("Item Level")

    def dedupe(name: str) -> str:
        if name not in used_names:
            used_names.add(name)
            return name
        i = 2
        while f"{name}_{i}" in used_names:
            i += 1
        final = f"{name}_{i}"
        used_names.add(final)
        return final

    names_by_col_id: dict[str, list[str]] = {}
    for col in columns:
        if col["type"] in SKIP_COLUMN_TYPES:
            names_by_col_id[col["id"]] = []
            continue
        title = col["title"]
        suffixes = MULTI_VALUE_SUFFIXES.get(col["type"])
        if suffixes:
            names_by_col_id[col["id"]] = [
                dedupe(f"{title}{suffix}") for suffix in suffixes
            ]
        else:
            names_by_col_id[col["id"]] = [dedupe(title)]

    return names_by_col_id


def build_schema_manifest(
    columns: list[dict],
    item_terminology: str | None = None,
    include_parent_id: bool = False,
    include_item_level: bool = False,
    names_by_col_id: dict[str, list[str]] | None = None,
) -> list[dict]:
    """One row per *output* column: its monday source column/type and the
    M type it should be cast to. This is the artifact to hand to
    Table.TransformColumnTypes when porting to M — no re-deriving needed.

    Pass an already-computed names_by_col_id (e.g. from build_dataframe) to
    skip re-deriving it — resolve_output_names is pure given the same inputs.
    """
    if names_by_col_id is None:
        names_by_col_id = resolve_output_names(
            columns, item_terminology, include_parent_id, include_item_level
        )
    manifest = []
    for col in columns:
        names = names_by_col_id[col["id"]]
        if not names:
            continue
        m_types = MONDAY_TYPE_TO_M_TYPES.get(col["type"], ["type text"] * len(names))
        for output_name, m_type in zip(names, m_types):
            manifest.append(
                {
                    "output_name": output_name,
                    "monday_column_title": col["title"],
                    "monday_column_id": col["id"],
                    "monday_type": col["type"],
                    "m_type": m_type,
                }
            )
    manifest.append(
        {
            "output_name": "item_id",
            "monday_column_title": None,
            "monday_column_id": "id",
            "monday_type": "id",
            "m_type": "Int64.Type",
        }
    )
    manifest.append(
        {
            "output_name": get_item_name_field(columns, item_terminology),
            "monday_column_title": None,
            "monday_column_id": "name",
            "monday_type": "name",
            "m_type": "type text",
        }
    )
    manifest.append(
        {
            "output_name": "Group",
            "monday_column_title": None,
            "monday_column_id": "group",
            "monday_type": "group",
            "m_type": "type text",
        }
    )
    if include_parent_id:
        manifest.append(
            {
                "output_name": "Parent ID",
                "monday_column_title": None,
                "monday_column_id": "parent_item",
                "monday_type": "parent_item",
                "m_type": "Int64.Type",
            }
        )
    if include_item_level:
        manifest.append(
            {
                "output_name": "Item Level",
                "monday_column_title": None,
                "monday_column_id": "item_level",
                "monday_type": "item_level",
                "m_type": "Int64.Type",
            }
        )
    return manifest


def collect_referenced_user_ids(columns: list[dict], items: list[dict]) -> set[str]:
    """User ids referenced by any creation_log/last_updated/people/person
    column_value, so they can all be resolved in one batched fetch_users() call.
    """
    log_col_ids = {
        c["id"] for c in columns if c["type"] in ("creation_log", "last_updated")
    }
    people_col_ids = {c["id"] for c in columns if c["type"] in ("people", "person")}
    if not log_col_ids and not people_col_ids:
        return set()
    user_ids: set[str] = set()
    for item in items:
        for cv in item["column_values"]:
            if cv["id"] in log_col_ids:
                user_id, _ = parse_user_log_value(cv.get("value"))
                if user_id:
                    user_ids.add(user_id)
            elif cv["id"] in people_col_ids:
                for p in cv.get("persons_and_teams") or []:
                    if p.get("kind") == "person" and p.get("id") is not None:
                        user_ids.add(str(p["id"]))
    return user_ids


def build_dataframe(
    columns: list[dict],
    items: list[dict],
    user_lookup: dict[str, dict] | None = None,
    item_terminology: str | None = None,
    include_parent_id: bool = False,
    item_levels: dict[str, int] | None = None,
) -> tuple[pd.DataFrame, list[dict]]:
    """Returns (df, schema_manifest). The schema is computed once here and
    returned alongside the DataFrame so callers (e.g. main(), for the schema
    JSON export) don't need to re-derive it from columns/flags a second time.
    """
    col_type_by_id = {c["id"]: c["type"] for c in columns}
    include_item_level = item_levels is not None
    names_by_col_id = resolve_output_names(
        columns, item_terminology, include_parent_id, include_item_level
    )
    board_relation_board_ids = get_board_relation_board_ids(columns)
    status_labels = get_status_labels(columns)
    item_name_field = get_item_name_field(columns, item_terminology)

    rows = []
    for item in items:
        row: dict[str, Any] = {"item_id": item["id"], item_name_field: item["name"]}
        row["Group"] = (item.get("group") or {}).get("title")
        if include_parent_id:
            parent_item = item.get("parent_item")
            row["Parent ID"] = parent_item["id"] if parent_item else None
        if item_levels is not None:
            row["Item Level"] = item_levels.get(item["id"])
        for cv in item["column_values"]:
            names = names_by_col_id.get(cv["id"], [])
            if not names:
                continue  # e.g. monday's built-in "Item ID" column, skipped
            col_type = col_type_by_id.get(cv["id"], cv["type"])
            value = parse_column_value(
                col_type, cv, user_lookup, board_relation_board_ids, status_labels
            )
            if len(names) == 1:
                row[names[0]] = value
            else:
                for name, part in zip(names, value):
                    row[name] = part
        rows.append(row)

    df = pd.DataFrame(rows)
    schema = build_schema_manifest(
        columns,
        item_terminology,
        include_parent_id,
        include_item_level,
        names_by_col_id,
    )
    return apply_output_dtypes(df, schema), schema


def apply_output_dtypes(df: pd.DataFrame, schema: list[dict]) -> pd.DataFrame:
    """Cast every output column to its schema-declared pandas dtype, rather
    than leaving it to pandas' per-column inference (which falls back to
    "object" for an all-null column even when we know it should be text/etc).
    """
    for entry in schema:
        name = entry["output_name"]
        if name not in df.columns:
            continue
        dtype = M_TYPE_TO_PANDAS_DTYPE[entry["m_type"]]
        if dtype == "datetime64[ns]":
            df[name] = pd.to_datetime(df[name], errors="coerce")
        else:
            df[name] = df[name].astype(dtype)
    return df


def sanitize_for_csv(df: pd.DataFrame) -> pd.DataFrame:
    """Collapse embedded newlines and neutralize formula-injection characters
    in text cells, ahead of CSV export.

    Multi-line text fields (e.g. a long "Recommendation" with paragraph
    breaks) are still valid, correctly-quoted CSV per RFC4180, but Excel's
    CSV parser is notoriously unreliable with them and can visually misalign
    every row after one.

    Board text is entered by anyone with edit access, and a cell starting
    with =, +, -, @, or tab is interpreted as a formula by Excel/Sheets on
    open (CSV/"formula" injection, OWASP-recognized) — prefixing with a
    single quote is the standard mitigation, forcing it to display as literal
    text instead of executing. Checked after the newline collapse above, so a
    cell that originally started with \\r/\\n (also an injection trigger) is
    already covered — it starts with a plain space by this point. Both are
    CSV-export-only concerns — the eventual M port reads straight from the
    GraphQL JSON, unaffected by either — so this is applied to a copy, not
    the returned DataFrame.
    """
    out = df.copy()
    for col in out.columns:
        if isinstance(out[col].dtype, pd.StringDtype):
            out[col] = out[col].str.replace(r"\r\n|\r|\n", " ", regex=True)
            out[col] = out[col].str.replace(r"^([=+\-@\t])", r"'\1", regex=True)
    return out


def main() -> None:
    api_key = get_api_key()

    item_levels: dict[str, int] | None = None
    suffix = ""

    # Always fetch main items first and classify the board BEFORE looking at
    # FETCH_SUBITEMS, so a multi-tier board can never be routed through the
    # classic subitems path (fetch_subitems() assumes a separate hidden
    # board and produces duplicated/misattributed rows if pointed at a
    # multi-tier board instead — see its docstring). This makes
    # FETCH_SUBITEMS a no-op on multi-tier boards rather than a footgun.
    board, columns, items = fetch_board(BOARD_ID, api_key)
    detected = detect_board_mode(BOARD_ID, items)

    if detected == "multi_tier":
        if FETCH_SUBITEMS:
            print(
                "NOTE: FETCH_SUBITEMS has no effect on multi-tier boards — "
                "auto-flattening instead."
            )
        # monday's newer nested-subitems feature: same board, same schema
        # at every tier. Auto-flatten — no switch needed.
        top_level_ids = [i["id"] for i in items if i.get("subitems")]
        column_ids = [c["id"] for c in columns]
        descendants = fetch_multi_tier_descendants(top_level_ids, column_ids, api_key)
        items = items + descendants
        item_levels = compute_item_levels(items)
        mode = "multi-tier (auto-flattened)"
        include_parent_id = True
    elif FETCH_SUBITEMS:
        # Classic single-level subitems on a separate hidden board. Discards
        # the board/columns/items fetched above — that fetch was only for
        # classification; this is a completely separate query path.
        board, columns, items = fetch_subitems(BOARD_ID, api_key)
        mode = "classic subitems (FETCH_SUBITEMS)"
        include_parent_id = True
        suffix = "_subitems"
    else:
        # "classic" (separate-board subitems exist but weren't requested via
        # FETCH_SUBITEMS) or "none" — unchanged main-items behavior.
        mode = "main items"
        include_parent_id = False

    item_terminology = board.get("item_terminology")

    print(f"Mode: {mode}")
    print(f"Board: {board['name']} (id={board['id']})")
    if DEBUG:
        print(f"Item terminology: {item_terminology!r}")
        print(f"Columns: {[(c['title'], c['type']) for c in columns]}")
    print(f"Items fetched: {len(items)}")

    user_ids = collect_referenced_user_ids(columns, items)
    user_lookup = fetch_users(user_ids, api_key)
    if user_ids:
        print(
            f"Resolved {len(user_lookup)}/{len(user_ids)} user ids from "
            "creation_log/last_updated/people/person columns"
        )

    df, schema = build_dataframe(
        columns, items, user_lookup, item_terminology, include_parent_id, item_levels
    )

    if DEBUG:
        print("\ndtypes:")
        print(df.dtypes)
        print("\nhead:")
        print(df.head(10))

    out_dir = os.path.join(os.path.dirname(__file__), "output")
    os.makedirs(out_dir, exist_ok=True)

    out_path = os.path.join(out_dir, f"board_{BOARD_ID}{suffix}.csv")
    # utf-8-sig: adds a UTF-8 BOM so Excel/Power Query's CSV connector auto-detect
    # UTF-8 instead of falling back to the Windows-1252 codepage (which mangles
    # non-ASCII characters like £ into "Â£").
    sanitize_for_csv(df).to_csv(out_path, index=False, encoding="utf-8-sig")
    print(f"\nWrote {len(df)} rows to {out_path}")

    schema_path = os.path.join(out_dir, f"board_{BOARD_ID}{suffix}_schema.json")
    with open(schema_path, "w", encoding="utf-8") as f:
        json.dump(schema, f, indent=2)
    print(f"Wrote schema manifest to {schema_path}")


if __name__ == "__main__":
    try:
        main()
    except requests.exceptions.RequestException as e:
        sys.exit(f"Network/API request to monday.com failed: {e}")
    except RuntimeError as e:
        sys.exit(f"monday.com API returned an error:\n{e}")
