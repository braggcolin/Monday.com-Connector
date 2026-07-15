// ============================================================================
// monday.com GraphQL board extractor
// ============================================================================
//
// Pulls a monday.com board's items (or, for multi-level boards, the full
// item tree) via the monday.com GraphQL API and shapes the result into a
// typed table: one row per item, one column per board column, with each
// column's output type resolved from the board's own column metadata.
//
// Structure:
//   Parameters             - the API credential and API version pin.
//   Type maps              - monday column type -> output field count/type.
//   GraphQL query text     - the request bodies sent to the API.
//   Core GraphQL plumbing  - authenticated requests, pagination, board and
//                            subitem fetching, multi-level tree flattening.
//   Column-value parsing   - one monday column type -> one output value.
//   Output shaping         - column-id-to-output-name resolution, schema
//                            manifest, row assembly, and type casting.
//   Orchestration          - Main, the single entry point that ties the
//                            above into one typed table per board.
//
// Requires one parameter, MondayApiKey, holding a monday.com API v2 token.
// Main(boardId, fetchSubitems) is the entry point: call it once per board,
// each call independent of the others, so multiple boards can be pulled
// into the same file without sharing state.
//
// Known limitations:
//   - "progress" (Progress Tracking) columns never return a usable value
//     through the API's column_values, even with capabilities:[CALCULATED],
//     for either a leaf item or a parent with real subitems — monday's own
//     documentation describes this value as calculated dynamically and only
//     usable for filtering, not retrieval. See ParseColumnValue's default
//     branch for the (unimplemented) client-side workaround this would need.
//   - `people`-type columns only resolve individual assignees to a name;
//     team assignees fall back to their raw id, since resolving a team
//     requires a separate GraphQL query this module doesn't issue.
//   - Classic (single-level) subitems live on a separate, auto-created
//     board with their own schema; FetchSubitemsClassic assumes that shape
//     and must never be called on a multi-level board — DetectBoardMode
//     exists specifically to make that routing decision safely.
//
section MondayExtract;

// ============================================================================
// Parameters
// ============================================================================

shared MondayApiKey = "" meta [
    IsParameterQuery = true,
    Type = "Text",
    IsParameterQueryRequired = true
];

shared ApiUrl = "https://api.monday.com/v2";
// Pinned API version; bump when monday.com exposes column features that
// need a newer version, and re-check the rollup/capabilities behavior
// documented near ColumnValuesFields still holds under the new version.
shared ApiVersion = "2026-07";

// ============================================================================
// Type maps
// ============================================================================

// Single source of truth for output column typing: a manifest of
// descriptive M-type names, keyed by monday column type. Types not listed
// here fall back to a same-length list of "type text" (see
// BuildSchemaManifest). Lists line up positionally with MultiValueSuffixes.
shared MondayTypeToMTypes = [
    numbers = {"type number"},
    checkbox = {"type logical"},
    date = {"type datetime"},
    timeline = {"type date", "type date"},
    link = {"type text", "type text"},
    creation_log = {"type text", "type text", "type datetime"},
    last_updated = {"type text", "type text", "type datetime"},
    // BoardID/ItemID kept as text (not Int64) since a board_relation column
    // can link to more than one item — multiple ids get "; "-joined.
    board_relation = {"type text", "type text", "type text"},
    people = {"type text", "type text"},
    person = {"type text", "type text"},
    // dependencies link to items on the SAME board, so no BoardID needed.
    dependency = {"type text", "type text"}
];

// Resolves a MondayTypeToMTypes / BuildSchemaManifest descriptive name to the
// actual M type value used by Table.TransformColumnTypes.
shared MTypeNameToType = [
    #"type text" = type text,
    #"type number" = type number,
    #"type logical" = type logical,
    #"type datetime" = type datetime,
    #"type date" = type date,
    #"Int64.Type" = Int64.Type
];

// Columns whose value is split into multiple output fields, and the name
// suffixes to use for each (applied to the column's display title).
shared MultiValueSuffixes = [
    timeline = {"_Start", "_End"},
    link = {"_URL", "_DisplayName"},
    creation_log = {"_User", "_Email", "_DateTime"},
    last_updated = {"_User", "_Email", "_DateTime"},
    board_relation = {"_DisplayName", "_BoardID", "_ItemID"},
    people = {"_Name", "_Email"},
    person = {"_Name", "_Email"},
    dependency = {"_DisplayName", "_ItemID"}
];

// item_id: monday's built-in "Item ID" column just redisplays item.id, which
// we already emit as our own item_id field — omit to avoid a duplicate.
// file: asset/attachment columns — not tabular data, drop entirely.
// name: the item-name pseudo-column, handled separately via
// GetItemNameField so its *title* becomes the item-name output field.
// subtasks: the built-in "Subitems" preview column — redundant now that
// multi-tier boards auto-flatten via Main.
shared SkipColumnTypes = {"item_id", "file", "name", "subtasks"};

// ============================================================================
// GraphQL query text
// ============================================================================

// board_relation, formula, mirror, and dependency columns often return empty
// text/value in the generic fields — monday's recommended way to read them
// is via their typed inline fragments instead.
//
// NumbersValue/DateValue/TimelineValue/BatteryValue are for multi-level
// board ROLLUP columns specifically: column_values for a rollup-capable
// column returns nothing at all — not even a leaf item's own directly-set
// value — unless column_values(capabilities: [CALCULATED]) is passed (see
// FirstItemsPageQuery/NextItemsQuery/MultiTierSubitemsQuery below). `is_leaf`
// distinguishes a static value (true) from a calculated/rolled-up one
// (false). Status rollups resolve to BatteryValue (a per-child-status-label
// count breakdown), not a plain label.
shared ColumnValuesFields = "
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
";

// Minimal probe used by DetectBoardMode, without paying for full
// column_values on every item's subitems.
shared SubitemsProbeField = "
        subitems {
          id
          board {
            id
          }
        }
";

shared BoardMetadataQuery = "
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
";

shared FirstItemsPageQuery = "
query ($boardId: [ID!], $columnIds: [String!]) {
  boards(ids: $boardId) {
    items_page(limit: 100) {
      cursor
      items {
        id
        name
        group {
          id
          title
        }
" & SubitemsProbeField & "
        column_values(ids: $columnIds, capabilities: [CALCULATED]) {
" & ColumnValuesFields & "
        }
      }
    }
  }
}
";

shared NextItemsQuery = "
query ($cursor: String!, $columnIds: [String!]) {
  next_items_page(limit: 100, cursor: $cursor) {
    cursor
    items {
      id
      name
      group {
        id
        title
      }
" & SubitemsProbeField & "
      column_values(ids: $columnIds, capabilities: [CALCULATED]) {
" & ColumnValuesFields & "
      }
    }
  }
}
";

// Fields for a subitem: its own id/name (a subitem is a full Item), the
// parent item's id (-> our "Parent ID" output field), and the subitems
// board's own metadata (read off the first subitem encountered, since
// monday's shared subitems board doesn't have a globally-known id you can
// query directly ahead of time).
shared SubitemFields = "
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
" & ColumnValuesFields & "
          }
";

shared SubitemsBoardQuery = "
query ($boardId: [ID!]) {
  boards(ids: $boardId) {
    id
    name
    items_page(limit: 100) {
      cursor
      items {
        id
        subitems {
" & SubitemFields & "
        }
      }
    }
  }
}
";

shared SubitemsNextItemsQuery = "
query ($cursor: String!) {
  next_items_page(limit: 100, cursor: $cursor) {
    cursor
    items {
      id
      subitems {
" & SubitemFields & "
      }
    }
  }
}
";

// status defaults to [ACTIVE, PENDING] — deactivated/removed users (common
// on older items) are silently excluded otherwise, and ParseColumnValue
// falls back to the bare numeric id when a person can't be resolved.
shared UsersQuery = "
query ($userIds: [ID!]) {
  users(ids: $userIds, status: [ACTIVE, INACTIVE, PENDING]) {
    id
    name
    email
  }
}
";

// Multi-tier boards: a single non-recursive `subitems` call on a top-level
// item already returns its FULL transitive descendant closure (monday
// flattens the whole subtree into one array, each entry carrying its own
// correct parent_item.id), so unlike SubitemFields this deliberately does
// NOT nest `subitems` inside itself.
shared MultiTierSubitemsQuery = "
query ($itemIds: [ID!], $columnIds: [String!]) {
  items(ids: $itemIds) {
    id
    subitems {
      id
      name
      group {
        id
        title
      }
      parent_item {
        id
      }
      column_values(ids: $columnIds, capabilities: [CALCULATED]) {
" & ColumnValuesFields & "
      }
    }
  }
}
";

// ============================================================================
// Core GraphQL plumbing
// ============================================================================

// On first run, Power BI/Excel will prompt for how to authenticate to
// api.monday.com — choose "Anonymous" (the API key travels in a custom
// header here, not through Web.Contents' own auth mechanisms).
shared RunQuery = (query as text, variables as record) as record =>
    let
        Response = Web.Contents(
            ApiUrl,
            [
                Headers = [
                    Authorization = MondayApiKey,
                    #"API-Version" = ApiVersion,
                    #"Content-Type" = "application/json"
                ],
                Content = Json.FromValue([query = query, variables = variables])
            ]
        ),
        Payload = Json.Document(Response),
        Result =
            if Record.HasFields(Payload, "errors") then
                error Error.Record(
                    "monday.com API error",
                    Text.FromBinary(Json.FromValue(Payload[errors]), TextEncoding.Utf8)
                )
            else
                Payload[data]
    in
        Result;

// One GraphQL call: board metadata + columns only — no items yet, since we
// need the column ids first to request column_values(ids: [...]) explicitly.
shared FetchBoardMetadata = (boardId as number) as record =>
    let
        Data = RunQuery(BoardMetadataQuery, [boardId = {Number.ToText(boardId)}]),
        Boards = Data[boards],
        Board =
            if List.IsEmpty(Boards) then
                error Error.Record(
                    "Board not found",
                    "No board found with id " & Number.ToText(boardId) & " (check the key has access to it)."
                )
            else
                Boards{0}
    in
        Board;

// One GraphQL call: the first items_page, with column_values scoped to the
// given column ids.
shared FetchFirstPage = (boardId as number, columnIds as list) as record =>
    let
        Data = RunQuery(
            FirstItemsPageQuery,
            [boardId = {Number.ToText(boardId)}, columnIds = columnIds]
        ),
        Boards = Data[boards],
        Board =
            if List.IsEmpty(Boards) then
                error Error.Record(
                    "Board not found",
                    "No board found with id " & Number.ToText(boardId) & " (check the key has access to it)."
                )
            else
                Boards{0}
    in
        Board[items_page];

// One GraphQL call: the next items_page for a given cursor.
shared FetchNextPage = (cursor as text, columnIds as list) as record =>
    RunQuery(NextItemsQuery, [cursor = cursor, columnIds = columnIds])[next_items_page];

// Returns [board = ..., columns = ..., items = ...] with pagination followed.
//
// List.Generate walks the cursor-based pagination: it always fetches the
// first page unconditionally, then keeps fetching and appending pages while
// the current page still returns a cursor, stopping the moment a page comes
// back with cursor = null.
shared FetchBoard = (boardId as number) as record =>
    let
        Board = FetchBoardMetadata(boardId),
        Columns = Board[columns],
        ColumnIds = List.Transform(Columns, each _[id]),
        FirstPage = FetchFirstPage(boardId, ColumnIds),
        Pages = List.Generate(
            () => FirstPage,
            each _ <> null,
            each if _[cursor] <> null then FetchNextPage(_[cursor], ColumnIds) else null
        ),
        Items = List.Combine(List.Transform(Pages, each _[items]))
    in
        [board = Board, columns = Columns, items = Items];

// Returns [board = subitems_board, columns = subitems_board_columns, items =
// subitems] — same shape as FetchBoard, so it flows through the exact same
// downstream pipeline (BuildDataframe, ApplyOutputDtypes, etc).
//
// Pagination still walks the PARENT board's items_page/next_items_page
// (same List.Generate shape as FetchBoard); subitems are nested inside each
// parent item and flattened out here. The subitems board's own metadata is
// read off the first subitem encountered, since monday's shared subitems
// board doesn't have a globally-known id you can query directly ahead of time.
shared FetchSubitemsClassic = (boardId as number) as record =>
    let
        Data = RunQuery(SubitemsBoardQuery, [boardId = {Number.ToText(boardId)}]),
        Boards = Data[boards],
        Board =
            if List.IsEmpty(Boards) then
                error Error.Record(
                    "Board not found",
                    "No board found with id " & Number.ToText(boardId) & " (check the key has access to it)."
                )
            else
                Boards{0},
        FirstPage = Board[items_page],
        Pages = List.Generate(
            () => FirstPage,
            each _ <> null,
            each if _[cursor] <> null then RunQuery(SubitemsNextItemsQuery, [cursor = _[cursor]])[next_items_page] else null
        ),
        ParentItems = List.Combine(List.Transform(Pages, each _[items])),
        Subitems = List.Combine(List.Transform(ParentItems, each if _[subitems] <> null then _[subitems] else {})),
        Checked =
            if List.IsEmpty(Subitems) then
                error Error.Record(
                    "No subitems found",
                    "No subitems found on board " & Number.ToText(boardId) & " (or none of its items have subitems)."
                )
            else
                Subitems,
        SubitemsBoard = Checked{0}[board]
    in
        [board = SubitemsBoard, columns = SubitemsBoard[columns], items = Checked];

// Classifies a board's subitems shape from the lightweight
// SubitemsProbeField already present on each item, without any extra
// GraphQL call:
//   "none"       — no item has subitems.
//   "classic"    — subitems exist and live on a DIFFERENT board (monday's
//                  older single-level subitems) — untouched here, still
//                  gated by the fetchSubitems argument to Main.
//   "multi_tier" — subitems exist and live on the SAME board as their
//                  parent — monday's newer nested-subitems feature, which
//                  Main auto-flattens (see FetchMultiTierDescendants).
shared DetectBoardMode = (boardId as number, items as list) as text =>
    let
        WithSubs = List.Select(items, each (if _[subitems] = null then {} else _[subitems]) <> {}),
        ItemWithSubs = if List.IsEmpty(WithSubs) then null else WithSubs{0},
        Result =
            if ItemWithSubs = null then
                "none"
            else
                let
                    SubBoardId = Text.From(ItemWithSubs[subitems]{0}[board][id])
                in
                    if SubBoardId = Text.From(boardId) then "multi_tier" else "classic"
    in
        Result;

// For multi-tier boards, a single non-recursive `subitems` call per item
// already returns its full transitive descendant closure, so this just
// batches that call across the given top-level item ids (25 per request,
// staying well under the API's list-argument size limits) and de-dupes by
// id as cheap insurance in case two top-level items' descendant sets ever
// overlap.
shared FetchMultiTierDescendants = (topLevelItemIds as list, columnIds as list) as list =>
    let
        Batches = List.Split(topLevelItemIds, 25),
        BatchItems = List.Combine(
            List.Transform(
                Batches,
                each RunQuery(MultiTierSubitemsQuery, [itemIds = _, columnIds = columnIds])[items]
            )
        ),
        AllSubitems = List.Combine(List.Transform(BatchItems, each if _[subitems] <> null then _[subitems] else {})),
        Deduped = List.Distinct(AllSubitems, each _[id])
    in
        Deduped;

// Depth of a single item in the tree, walked from parent_item chains: a
// top-level item (no parent) is level 1, everything else is its parent's
// level + 1. `chain` accumulates the ids visited on the way up so a cyclic
// parent_item chain raises an error instead of recursing indefinitely.
shared FindLevel = (itemId as text, parentById as record, chain as list) as number =>
    let
        ParentId = Record.FieldOrDefault(parentById, itemId, null),
        Result =
            if List.Contains(chain, itemId) then
                error Error.Record("Cycle detected", "Cycle detected in parent_item chain at item " & itemId)
            else if ParentId = null then
                1
            else
                @FindLevel(ParentId, parentById, chain & {itemId}) + 1
    in
        Result;

shared ComputeItemLevels = (items as list) as record =>
    let
        // Only descendants fetched via MultiTierSubitemsQuery carry a
        // parent_item field at all; top-level items from
        // FirstItemsPageQuery/NextItemsQuery never request it, so this must
        // be a safe lookup (Record.FieldOrDefault), not direct [parent_item]
        // field access, which errors on a record that lacks the field.
        ParentById = List.Accumulate(
            items,
            [],
            (state, item) =>
                let ParentItem = Record.FieldOrDefault(item, "parent_item", null)
                in Record.AddField(
                    state,
                    Text.From(item[id]),
                    if ParentItem <> null then Text.From(ParentItem[id]) else null
                )
        ),
        Levels = List.Accumulate(
            items,
            [],
            (state, item) => Record.AddField(state, Text.From(item[id]), FindLevel(Text.From(item[id]), ParentById, {}))
        )
    in
        Levels;

// One GraphQL call resolving user ids -> {id, name, email}. Needed because
// creation_log/last_updated column_values only carry a user id, not the
// display name or email.
shared FetchUsers = (userIds as list) as record =>
    if List.IsEmpty(userIds) then
        []
    else
        let
            Data = RunQuery(UsersQuery, [userIds = List.Sort(userIds)]),
            Users = Data[users]
        in
            List.Accumulate(Users, [], (state, u) => Record.AddField(state, Text.From(u[id]), u));

// ============================================================================
// Column-value parsing
// ============================================================================

// Extract [userId = ..., timestamp = ...] from a creation_log/last_updated
// value. creation_log's JSON shape is {"created_at": "...Z", "creator_id":
// "..."}; last_updated's key names can vary by API version, so several
// likely variants are checked as fallbacks to stay robust across versions.
shared ParseUserLogValue = (rawValue as nullable text) as record =>
    if rawValue = null or rawValue = "null" then
        [userId = null, timestamp = null]
    else
        let
            Parsed = Json.Document(rawValue),
            UserId =
                if Record.HasFields(Parsed, "creator_id") and Parsed[creator_id] <> null then Parsed[creator_id]
                else if Record.HasFields(Parsed, "updater_id") and Parsed[updater_id] <> null then Parsed[updater_id]
                else if Record.HasFields(Parsed, "changer_id") and Parsed[changer_id] <> null then Parsed[changer_id]
                else if Record.HasFields(Parsed, "user_id") and Parsed[user_id] <> null then Parsed[user_id]
                else null,
            Timestamp =
                if Record.HasFields(Parsed, "created_at") and Parsed[created_at] <> null then Parsed[created_at]
                else if Record.HasFields(Parsed, "updated_at") and Parsed[updated_at] <> null then Parsed[updated_at]
                else if Record.HasFields(Parsed, "changed_at") and Parsed[changed_at] <> null then Parsed[changed_at]
                else null
        in
            [userId = if UserId <> null then Text.From(UserId) else null, timestamp = Timestamp];

shared ParseLogTimestamp = (rawTimestamp as any) as nullable datetime =>
    let
        IsNumericMs =
            rawTimestamp <> null and (
                Value.Is(rawTimestamp, type number)
                or (Value.Is(rawTimestamp, type text) and rawTimestamp <> "" and Text.Length(Text.Select(rawTimestamp, {"0".."9"})) = Text.Length(rawTimestamp))
            ),
        Result =
            if rawTimestamp = null then null
            else if IsNumericMs then #datetime(1970, 1, 1, 0, 0, 0) + #duration(0, 0, 0, Number.From(rawTimestamp) / 1000)
            else try DateTime.FromText(Text.From(rawTimestamp)) otherwise null
    in
        Result;

// Extract "; "-joined connected board ids from a board_relation column's
// settings_str. This is column *configuration* (which board(s) it can link
// to), identical for every item, so it's parsed once per column here rather
// than guessed at from each item's value JSON.
shared ParseBoardRelationSettings = (settingsStr as nullable text) as nullable text =>
    if settingsStr = null or settingsStr = "null" then
        null
    else
        let
            Parsed = Json.Document(settingsStr),
            RawIds = if Record.HasFields(Parsed, "boardIds") and Parsed[boardIds] <> null then Parsed[boardIds] else {},
            BoardIds = List.Distinct(List.Transform(List.Select(RawIds, each _ <> null), each Text.From(_)))
        in
            if List.IsEmpty(BoardIds) then null else Text.Combine(BoardIds, "; ");

// column id -> "; "-joined connected board id(s), for board_relation columns.
shared GetBoardRelationBoardIds = (columns as list) as record =>
    List.Accumulate(
        List.Select(columns, each _[#"type"] = "board_relation"),
        [],
        (state, c) => Record.AddField(state, c[id], ParseBoardRelationSettings(c[settings_str]))
    );

// Extract {label index -> label text} from a status column's settings_str.
// Needed to turn a rollup Status column's BatteryValue (index/count pairs)
// back into readable text, since BatteryValue only carries the index.
shared ParseStatusLabels = (settingsStr as nullable text) as record =>
    if settingsStr = null or settingsStr = "null" then
        []
    else
        let
            Parsed = Json.Document(settingsStr)
        in
            if Record.HasFields(Parsed, "labels") and Parsed[labels] <> null then Parsed[labels] else [];

// column id -> {label index -> label text}, for status columns.
shared GetStatusLabels = (columns as list) as record =>
    List.Accumulate(
        List.Select(columns, each _[#"type"] = "status"),
        [],
        (state, c) => Record.AddField(state, c[id], ParseStatusLabels(c[settings_str]))
    );

// The display label for the item-name field, using the same precedence the
// monday UI uses for that column's header:
//   1. board.item_terminology (boards can rename what an "item" is called).
//   2. the "name"-type pseudo-column's title.
//   3. "item_name" if neither is available.
shared GetItemNameField = (columns as list, optional itemTerminology as nullable text) as text =>
    if itemTerminology <> null and itemTerminology <> "" then
        itemTerminology
    else
        let
            NameCols = List.Select(columns, each _[#"type"] = "name")
        in
            if not List.IsEmpty(NameCols) then NameCols{0}[title] else "item_name";

// Shared by board_relation and dependency: both resolve to the same
// `linked_items { id name }` shape and both need "; "-joined display names
// and ids (a column can link to more than one item).
shared LinkedItemsDisplayAndIds = (linkedItems as list, fallbackText as nullable text) as record =>
    let
        Named = List.Select(linkedItems, each _[name] <> null and _[name] <> ""),
        DisplayName = if List.IsEmpty(Named) then fallbackText else Text.Combine(List.Transform(Named, each _[name]), "; "),
        WithIds = List.Select(linkedItems, each _[id] <> null),
        ItemIdStr = if List.IsEmpty(WithIds) then null else Text.Combine(List.Transform(WithIds, each Text.From(_[id])), "; ")
    in
        [displayName = DisplayName, itemId = ItemIdStr];

// Map a monday.com column_value to its output value(s) based on its type.
// Always returns a list, positionally aligned with MultiValueSuffixes (a
// single-element list for scalar types) — never a bare value — so callers
// can always zip it against ResolveOutputNames' output names.
shared ParseColumnValue = (
    colType as text,
    cv as record,
    userLookup as nullable record,
    boardRelationBoardIds as nullable record,
    statusLabels as nullable record
) as list =>
    let
        Text_ = Record.FieldOrDefault(cv, "text", null),
        RawValue = Record.FieldOrDefault(cv, "value", null),
        Result =
            if colType = "numbers" then
                // NumbersValue.number is how rollup-capable Numbers columns on
                // multi-level boards return their value (plain text/value come
                // back empty for those). Falls back to text otherwise.
                let Num = Record.FieldOrDefault(cv, "number", null)
                in {if Num <> null then Num else (try Number.FromText(Text_) otherwise null)}

            else if colType = "checkbox" then
                let
                    Checked =
                        if RawValue <> null and RawValue <> "null" then
                            let
                                Parsed = Json.Document(RawValue),
                                C = Record.FieldOrDefault(Parsed, "checked", null)
                            in
                                // monday has returned this both as a JSON bool and
                                // as the string "true" across API versions/configs.
                                (C = true) or (Value.Is(C, type text) and Text.Lower(C) = "true")
                        else
                            false
                in
                    {Checked}

            else if colType = "date" then
                {
                    if RawValue <> null and RawValue <> "null" then
                        let
                            Parsed = Json.Document(RawValue),
                            DatePart = Record.FieldOrDefault(Parsed, "date", null),
                            TimePart = Record.FieldOrDefault(Parsed, "time", null)
                        in
                            if DatePart <> null and TimePart <> null then try DateTime.FromText(DatePart & " " & TimePart) otherwise null
                            else if DatePart <> null then try DateTime.FromText(DatePart) otherwise null
                            else null
                    else
                        null
                }

            else if colType = "timeline" then
                let
                    From_ = Record.FieldOrDefault(cv, "from", null),
                    To_ = Record.FieldOrDefault(cv, "to", null),
                    Parsed =
                        // TimelineValue.from/to is how rollup-capable Timeline
                        // columns on multi-level boards return their value.
                        if From_ <> null or To_ <> null then
                            [start = try DateTime.FromText(From_) otherwise null, end_ = try DateTime.FromText(To_) otherwise null]
                        else if RawValue <> null and RawValue <> "null" then
                            let J = Json.Document(RawValue)
                            in [
                                start = try DateTime.FromText(Record.FieldOrDefault(J, "from", null)) otherwise null,
                                end_ = try DateTime.FromText(Record.FieldOrDefault(J, "to", null)) otherwise null
                            ]
                        else if Text_ <> null and Text_ <> "" then
                            // fallback: monday renders text as "MM/DD/YYYY - MM/DD/YYYY"
                            let Parts = List.Transform(Text.Split(Text_, " - "), Text.Trim)
                            in
                                if List.Count(Parts) = 2 then
                                    [start = try DateTime.FromText(Parts{0}) otherwise null, end_ = try DateTime.FromText(Parts{1}) otherwise null]
                                else
                                    [start = null, end_ = null]
                        else
                            [start = null, end_ = null]
                in
                    {Parsed[start], Parsed[end_]}

            else if colType = "link" then
                if RawValue <> null and RawValue <> "null" then
                    let J = Json.Document(RawValue)
                    in {Record.FieldOrDefault(J, "url", null), Record.FieldOrDefault(J, "text", null)}
                else
                    {null, Text_}

            else if colType = "board_relation" then
                let
                    Linked = let L = Record.FieldOrDefault(cv, "linked_items", {}) in if L = null then {} else L,
                    LinkedResult = LinkedItemsDisplayAndIds(Linked, Text_),
                    BoardIdStr = if boardRelationBoardIds <> null then Record.FieldOrDefault(boardRelationBoardIds, cv[id], null) else null
                in
                    {LinkedResult[displayName], BoardIdStr, LinkedResult[itemId]}

            else if colType = "creation_log" or colType = "last_updated" then
                let
                    Parsed = ParseUserLogValue(RawValue),
                    User = if Parsed[userId] <> null and userLookup <> null then Record.FieldOrDefault(userLookup, Parsed[userId], null) else null
                in
                    {
                        if User <> null then Record.FieldOrDefault(User, "name", null) else null,
                        if User <> null then Record.FieldOrDefault(User, "email", null) else null,
                        ParseLogTimestamp(Parsed[timestamp])
                    }

            else if colType = "formula" or colType = "mirror" then
                // formula: the computed result, not the formula definition.
                // mirror: deliberately plain text, not the mirrored column's
                // real type — if that's needed, pull both boards and relate them.
                let DV = Record.FieldOrDefault(cv, "display_value", null)
                in {if DV <> null and DV <> "" then DV else Text_}

            else if colType = "dependency" then
                let Linked = let L = Record.FieldOrDefault(cv, "linked_items", {}) in if L = null then {} else L,
                    LinkedResult = LinkedItemsDisplayAndIds(Linked, Text_)
                in
                    {LinkedResult[displayName], LinkedResult[itemId]}

            else if colType = "people" or colType = "person" then
                let
                    Assignees = let A = Record.FieldOrDefault(cv, "persons_and_teams", {}) in if A = null then {} else A,
                    // teams have no email to resolve; text already covers the name.
                    People = List.Select(Assignees, each _[kind] = "person"),
                    Names = List.Transform(
                        People,
                        each
                            let U = if userLookup <> null then Record.FieldOrDefault(userLookup, Text.From(_[id]), null) else null
                            in if U <> null and Record.FieldOrDefault(U, "name", null) <> null then U[name] else Text.From(_[id])
                    ),
                    Emails = List.RemoveNulls(
                        List.Transform(
                            People,
                            each
                                let U = if userLookup <> null then Record.FieldOrDefault(userLookup, Text.From(_[id]), null) else null
                                in if U <> null then Record.FieldOrDefault(U, "email", null) else null
                        )
                    ),
                    DisplayName = if List.IsEmpty(Names) then Text_ else Text.Combine(Names, "; "),
                    EmailStr = if List.IsEmpty(Emails) then null else Text.Combine(Emails, "; ")
                in
                    {DisplayName, EmailStr}

            else if colType = "status" then
                // BatteryValue is how a rollup-capable Status column on a
                // multi-level board returns its value — a label-index/count
                // breakdown (a single leaf item's own status is just one index
                // with count=1), needing translation via the column's own
                // settings_str label map. Falls back to text otherwise.
                let Battery = Record.FieldOrDefault(cv, "battery_value", null)
                in
                    if Battery <> null and not List.IsEmpty(Battery) then
                        let
                            Labels = if statusLabels <> null then Record.FieldOrDefault(statusLabels, cv[id], []) else [],
                            SingleEntry = List.Count(Battery) = 1, // a leaf's own status: count is redundant noise
                            Parts = List.Transform(
                                Battery,
                                each
                                    let
                                        KeyStr = Text.From(_[key]),
                                        Label = Record.FieldOrDefault(Labels, KeyStr, KeyStr)
                                    in
                                        if SingleEntry then Label else Label & " (" & Text.From(_[count]) & ")"
                            )
                        in
                            {if List.IsEmpty(Parts) then Text_ else Text.Combine(Parts, "; ")}
                    else
                        {Text_}

            else
                // dropdown, email, phone, long_text, text, progress, etc.
                // `text` is monday's own human-readable rendering of the
                // value — sufficient for every remaining column type except
                // "progress" (Progress Tracking), which always renders empty:
                // monday computes that percentage dynamically and only
                // exposes it for filtering, not retrieval, via column_values
                // (confirmed against the API directly, including with
                // capabilities:[CALCULATED]). Deriving it client-side would
                // mean reading the column's settings_str for which Status
                // column and labels it tracks, then recomputing the
                // percentage from that Status column's own rollup data.
                {Text_}
    in
        Result;

// ============================================================================
// Output shaping
// ============================================================================

shared FindFreeSuffix = (name as text, used as list, i as number) as number =>
    if not List.Contains(used, name & "_" & Text.From(i)) then i else @FindFreeSuffix(name, used, i + 1);

// Map each column id to its output field name(s), using display titles (not
// monday's internal ids) and de-duplicating collisions with _2, _3, ....
// Columns listed in MultiValueSuffixes produce multiple names (e.g. timeline
// -> "<Title>_Start"/"<Title>_End"). Columns in SkipColumnTypes produce no
// output name at all.
shared ResolveOutputNames = (
    columns as list,
    optional itemTerminology as nullable text,
    optional includeParentId as nullable logical,
    optional includeItemLevel as nullable logical
) as record =>
    let
        ItemNameField = GetItemNameField(columns, itemTerminology),
        InitialUsed = {"item_id", ItemNameField, "Group"}
            & (if includeParentId = true then {"Parent ID"} else {})
            & (if includeItemLevel = true then {"Item Level"} else {}),
        Dedupe = (name as text, used as list) as record =>
            if not List.Contains(used, name) then
                [name = name, used = used & {name}]
            else
                let
                    Idx = FindFreeSuffix(name, used, 2),
                    Final = name & "_" & Text.From(Idx)
                in
                    [name = Final, used = used & {Final}],
        Folded = List.Accumulate(
            columns,
            [namesByColId = [], used = InitialUsed],
            (state, col) =>
                if List.Contains(SkipColumnTypes, col[#"type"]) then
                    [namesByColId = Record.AddField(state[namesByColId], col[id], {}), used = state[used]]
                else
                    let
                        Suffixes = Record.FieldOrDefault(MultiValueSuffixes, col[#"type"], null),
                        Titles = if Suffixes <> null then List.Transform(Suffixes, each col[title] & _) else {col[title]},
                        TitlesFolded = List.Accumulate(
                            Titles,
                            [names = {}, used = state[used]],
                            (s2, t) =>
                                let D = Dedupe(t, s2[used])
                                in [names = s2[names] & {D[name]}, used = D[used]]
                        )
                    in
                        [namesByColId = Record.AddField(state[namesByColId], col[id], TitlesFolded[names]), used = TitlesFolded[used]]
        )
    in
        Folded[namesByColId];

// One row per *output* column: its monday source column/type and the M type
// it should be cast to. Feeds ApplyOutputDtypes' Table.TransformColumnTypes
// call directly — no re-deriving needed.
shared BuildSchemaManifest = (
    columns as list,
    optional itemTerminology as nullable text,
    optional includeParentId as nullable logical,
    optional includeItemLevel as nullable logical,
    optional namesByColId as nullable record
) as list =>
    let
        NamesByColId = if namesByColId <> null then namesByColId else ResolveOutputNames(columns, itemTerminology, includeParentId, includeItemLevel),
        ColumnRows = List.Combine(
            List.Transform(
                columns,
                (col) =>
                    let
                        Names = Record.FieldOrDefault(NamesByColId, col[id], {}),
                        MTypesDefault = List.Repeat({"type text"}, List.Count(Names)),
                        MTypes = Record.FieldOrDefault(MondayTypeToMTypes, col[#"type"], MTypesDefault)
                    in
                        if List.IsEmpty(Names) then
                            {}
                        else
                            List.Transform(
                                List.Positions(Names),
                                (i) => [
                                    output_name = Names{i},
                                    monday_column_title = col[title],
                                    monday_column_id = col[id],
                                    monday_type = col[#"type"],
                                    m_type = MTypes{i}
                                ]
                            )
            )
        ),
        ItemNameField = GetItemNameField(columns, itemTerminology),
        BaseRows = {
            [output_name = "item_id", monday_column_title = null, monday_column_id = "id", monday_type = "id", m_type = "Int64.Type"],
            [output_name = ItemNameField, monday_column_title = null, monday_column_id = "name", monday_type = "name", m_type = "type text"],
            [output_name = "Group", monday_column_title = null, monday_column_id = "group", monday_type = "group", m_type = "type text"]
        },
        ParentRows = if includeParentId = true then {[output_name = "Parent ID", monday_column_title = null, monday_column_id = "parent_item", monday_type = "parent_item", m_type = "Int64.Type"]} else {},
        LevelRows = if includeItemLevel = true then {[output_name = "Item Level", monday_column_title = null, monday_column_id = "item_level", monday_type = "item_level", m_type = "Int64.Type"]} else {}
    in
        ColumnRows & BaseRows & ParentRows & LevelRows;

// User ids referenced by any creation_log/last_updated/people/person
// column_value, so they can all be resolved in one batched FetchUsers call.
shared CollectReferencedUserIds = (columns as list, items as list) as list =>
    let
        LogColIds = List.Transform(List.Select(columns, each _[#"type"] = "creation_log" or _[#"type"] = "last_updated"), each _[id]),
        PeopleColIds = List.Transform(List.Select(columns, each _[#"type"] = "people" or _[#"type"] = "person"), each _[id]),
        Result =
            if List.IsEmpty(LogColIds) and List.IsEmpty(PeopleColIds) then
                {}
            else
                List.Distinct(
                    List.Combine(
                        List.Transform(
                            items,
                            (item) =>
                                List.Combine(
                                    List.Transform(
                                        item[column_values],
                                        (cv) =>
                                            if List.Contains(LogColIds, cv[id]) then
                                                let Parsed = ParseUserLogValue(Record.FieldOrDefault(cv, "value", null))
                                                in if Parsed[userId] <> null then {Parsed[userId]} else {}
                                            else if List.Contains(PeopleColIds, cv[id]) then
                                                let People = let A = Record.FieldOrDefault(cv, "persons_and_teams", {}) in if A = null then {} else A
                                                in List.Transform(List.Select(People, each _[kind] = "person" and _[id] <> null), each Text.From(_[id]))
                                            else
                                                {}
                                    )
                                )
                        )
                    )
                )
    in
        Result;

// Cast every output column to its schema-declared M type, rather than
// leaving it to Table.FromRecords' own inference (which falls back to `any`
// for an all-null column even when the schema says it should be text/etc).
shared ApplyOutputDtypes = (tbl as table, schema as list) as table =>
    let
        ExistingCols = Table.ColumnNames(tbl),
        Specs = List.Transform(
            List.Select(schema, each List.Contains(ExistingCols, _[output_name])),
            each {_[output_name], Record.Field(MTypeNameToType, _[m_type])}
        )
    in
        Table.TransformColumnTypes(tbl, Specs);

// Returns [table = ..., schema = ...]. The schema is computed once here and
// returned alongside the table so callers don't need to re-derive it from
// columns/flags a second time.
shared BuildDataframe = (
    columns as list,
    items as list,
    optional userLookup as nullable record,
    optional itemTerminology as nullable text,
    optional includeParentId as nullable logical,
    optional itemLevels as nullable record
) as record =>
    let
        ColTypeById = List.Accumulate(columns, [], (state, c) => Record.AddField(state, c[id], c[#"type"])),
        IncludeItemLevel = itemLevels <> null,
        NamesByColId = ResolveOutputNames(columns, itemTerminology, includeParentId, IncludeItemLevel),
        BoardRelationBoardIds = GetBoardRelationBoardIds(columns),
        StatusLabels = GetStatusLabels(columns),
        ItemNameField = GetItemNameField(columns, itemTerminology),

        RowFor = (item as record) as record =>
            let
                Base = Record.AddField([item_id = item[id]], ItemNameField, item[name]),
                WithGroup = Record.AddField(Base, "Group", if item[group] <> null then item[group][title] else null),
                // Same "field may not exist at all" case as ComputeItemLevels:
                // top-level items never carry parent_item, only descendants do.
                ParentItem = Record.FieldOrDefault(item, "parent_item", null),
                WithParent =
                    if includeParentId = true then
                        Record.AddField(WithGroup, "Parent ID", if ParentItem <> null then ParentItem[id] else null)
                    else
                        WithGroup,
                WithLevel =
                    if itemLevels <> null then
                        Record.AddField(WithParent, "Item Level", Record.FieldOrDefault(itemLevels, Text.From(item[id]), null))
                    else
                        WithParent
            in
                List.Accumulate(
                    item[column_values],
                    WithLevel,
                    (rowState, cv) =>
                        let Names = Record.FieldOrDefault(NamesByColId, cv[id], {})
                        in
                            if List.IsEmpty(Names) then
                                rowState
                            else
                                let
                                    ColType = Record.FieldOrDefault(ColTypeById, cv[id], cv[#"type"]),
                                    Values = ParseColumnValue(ColType, cv, userLookup, BoardRelationBoardIds, StatusLabels),
                                    Pairs = List.Zip({Names, Values})
                                in
                                    List.Accumulate(Pairs, rowState, (s2, pair) => Record.AddField(s2, pair{0}, pair{1}))
                ),

        Rows = List.Transform(items, RowFor),
        RawTable = Table.FromRecords(Rows, null, MissingField.UseNull),
        Schema = BuildSchemaManifest(columns, itemTerminology, includeParentId, IncludeItemLevel, NamesByColId),
        TypedTable = ApplyOutputDtypes(RawTable, Schema)
    in
        [table = TypedTable, schema = Schema];

// ============================================================================
// Orchestration
// ============================================================================

// The single entry point: given a board id, returns [table = ..., schema =
// ..., board = ..., mode = ...] for that board. boardId and fetchSubitems
// are ordinary function arguments rather than global parameters, so each
// call is independent — pulling several boards into the same file just
// means calling Main once per board, with no shared state between calls.
//
// Always fetch main items first and classify the board BEFORE looking at
// fetchSubitems, so a multi-tier board can never be routed through the
// classic subitems path (FetchSubitemsClassic assumes a separate hidden
// board and would produce duplicated/misattributed rows if pointed at a
// multi-tier board instead). This makes fetchSubitems a no-op on multi-tier
// boards rather than a footgun.
shared Main = (boardId as number, optional fetchSubitems as nullable logical) as record =>
    let
        BoardMeta = FetchBoard(boardId),
        Mode = DetectBoardMode(boardId, BoardMeta[items]),

        Routed =
            if Mode = "multi_tier" then
                // monday's newer nested-subitems feature: same board, same
                // schema at every tier. Auto-flatten — no switch needed.
                let
                    TopLevelIds = List.Transform(
                        List.Select(BoardMeta[items], each (if _[subitems] = null then {} else _[subitems]) <> {}),
                        each _[id]
                    ),
                    ColumnIds = List.Transform(BoardMeta[columns], each _[id]),
                    Descendants = FetchMultiTierDescendants(TopLevelIds, ColumnIds),
                    AllItems = BoardMeta[items] & Descendants
                in
                    [
                        board = BoardMeta[board],
                        columns = BoardMeta[columns],
                        items = AllItems,
                        itemLevels = ComputeItemLevels(AllItems),
                        includeParentId = true
                    ]
            else if fetchSubitems = true then
                // Classic single-level subitems on a separate hidden board.
                // Discards the board/columns/items fetched above — that fetch
                // was only for classification; this is a separate query path.
                let Sub = FetchSubitemsClassic(boardId)
                in [board = Sub[board], columns = Sub[columns], items = Sub[items], itemLevels = null, includeParentId = true]
            else
                // "classic" (separate-board subitems exist but weren't
                // requested) or "none" — unchanged main-items behavior.
                [board = BoardMeta[board], columns = BoardMeta[columns], items = BoardMeta[items], itemLevels = null, includeParentId = false],

        ItemTerminology = Record.FieldOrDefault(Routed[board], "item_terminology", null),
        UserIds = CollectReferencedUserIds(Routed[columns], Routed[items]),
        UserLookup = FetchUsers(UserIds),

        Built = BuildDataframe(
            Routed[columns],
            Routed[items],
            UserLookup,
            ItemTerminology,
            Routed[includeParentId],
            Routed[itemLevels]
        )
    in
        [table = Built[table], schema = Built[schema], board = Routed[board], mode = Mode];
