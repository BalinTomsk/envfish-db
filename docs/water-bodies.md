# Water bodies in FishFind

What a "water body" is in this database, how it is stored, and the traps that cost time. Read this before writing
SQL, an API endpoint or an MCP tool that touches water bodies. Schema source of truth: `mssql/script01_createTable.sql`
(tables), `mssql/script02_Funct.sql` (functions), `mssql/script08_Data.sql` (seed data).

## One table for every kind

Every lake, river, creek, pond, reservoir, bay, canal and so on is **one row in `dbo.lake`** (the table is called
`Lake`, whatever the type). Its key `lake_id` is a GUID; the APIs and the MCP tools call it `lakeId` / `guid`. About
205k rows (CTRL envionx, 2026-10-18), Canada and the USA (Maine is the first US state, imported 2026-10-18).

Apps never read the table directly: they go through a view, function or procedure (envfish-db rule). The main
readers are `dbo.vw_lake` (one row per water body with source and mouth columns joined in),
`dbo.fn_lake_view_json` (the full description document), `dbo.fn_river_search_json` (search and ranking) and
`dbo.SearchLakeList` (the portal's free-text search).

## Type: `locType` is a bitmask

| bit   | type | rows (CTRL) |
|------:|------|------------:|
| 1     | lake (also bays, coves, arms — see `ltype`) | 118,647 |
| 2     | river | 15,323 |
| 4     | stream | 14,354 |
| 8     | pond | 12,545 |
| 16    | marsh | |
| 32    | backwater | |
| 64    | creek (brook, burn, run) | 39,407 |
| 128   | canal (channel, strait) | 3,253 |
| 256   | estuary | |
| 512   | shore | |
| 1024  | drain | |
| 2048  | ditch | |
| 4096  | wetland | |
| 8192  | reservoir | 813 |
| 16384 | ocean / sea (seeded as 16385 = 16384 \| 1) | |

The types fall into two near-equivalent groups:
- **still water** — lake (1), pond (8), reservoir (8192);
- **flowing water** — river (2), stream (4), creek (64), canal (128).

Within a group the type is mostly a naming choice of the source data, so a filter or a ranking for one type usually
wants the whole group (e.g. `types: [river, stream, creek, canal]`, bitmask 198; still water = 8201).

A filter "matches" when it shares any bit (`locType & @mask <> 0`). The MCP tools take names instead of numbers
(`McpToolCatalog.WATER_BODY_TYPES` in docapi); REST endpoints take the number (`locType=`, `river=`).

Two lookup tables explain the types:
- **`dbo.water_body`** (`script08_Data.sql`) — one row per English generic word (`Lake`, `River`, `Creek`, `Bay`,
  `Strait`, …) with its French word, `locType`, `speed` (0 still, 4 normal, 8 stream) and a one-line `description`.
  `dbo.fn_clean_river_name` and `dbo.GetValidPart` use it to split a name into "base name + type word". French words are written with
  `nchar()` in the seed on purpose (code-page safety).
- **`dbo.ltype`** — CGNDB generic terms (`Arm`, `Bite`, `Coves`, `Brook`, …) mapped to a concise class (`LAKE`, `BAY`,
  `RIV`, …) and a `locType`. Imports use it to type a new feature; BAY/CHAN features follow it on purpose.

## Identity: three kinds of id

**Why one water body can have two GUIDs and two CGNDB keys.** A Canadian water body can cross two provinces, and the
sources (CGNDB, the provincial hydro data) record it once **per province** — so it first arrives as two `dbo.lake`
rows, one for each province. Sooner or later the two are **merged into a single row** with `exec dbo.sp_MergeLakes`,
which exists for exactly this operation: the survivor keeps its own GUID and CGNDB key and takes the other row's as its
second ones (`secondary_id`, `CGNDM`), so both old ids still find it (Reindeer Lake: MB `GAWWT` + SK `HAINF`). 521
such pairs were merged on 2026-10-10 and 21 more on 2026-10-18.

**Never call `sp_MergeLakes` bare for a batch** — wrap it, as both batches did. It (1) overwrites the survivor's lake
fields with the merged row's (`link` always, the rest where the merged row has a value); (2) copies the merged row's
source/mouth attributes onto the survivor's **without matching source to source** — a mouth can come out holding
the other row's source point; (3) moves the CGNDB key to `CGNDM` but does **not** keep the merged row's GUID in
`secondary_id` (the 2026-10-10 batch left it empty; the 2026-10-18 one fills it); (4) swallows its own errors, so a
failed merge can look like a success. A one-row-per-pair transaction with `XACT_ABORT ON`, then restoring the
survivor's fields, setting source = survivor's and mouth = the merged row's (the other province's end, so "source OR
mouth in a state" finds it in both), is the pattern; `ADMIN_WRITE_lake_merge_two_province.sql` (2026-10-18, deleted
once applied) was its latest form.

- **`lake_id`** — the GUID; **`secondary_id`** — the merged row's GUID. Both are searchable (`guid=` matches either).
- **`CGNDB` / `CGNDM`** (`varchar(10)`) — the national non-GUID id. In Canada the 5-letter Canadian Geographical
  Names key (`FEFUL`), one per province: the merged row's key goes in `CGNDM`. **In the USA it is the GNIS feature
  id, 6–7 digits** (`570304`). Both columns are unique when set, and `cgndb=` matches either. Consequence: "has a
  CGNDB code" no longer means "Canadian" — only a 5-letter key does.
- **`state_id`** (`varchar(32)`) — the province's/state's own id (BC Geographical Names id = FWA `GNIS_ID`, Alberta
  FWMIS id, Manitoba `WATERBODY_ID`, Newfoundland salmon river `SSR-n`, PEI watershed id, …). **Not unique**: two
  provinces' ranges overlap, so read it together with the water body's state.

Names: `lake_name` (primary, `nvarchar(64)`), `alt_name`, `french_name`, `former_name`, `spanish_name`,
`original_name`, `native`. `symbol` is the first letter, for the A–Z browse. About 9.6k names carry mojibake from old
CHN loads.

## Where it is: source, mouth and other links (`dbo.Tributaries`)

A water body has no country or state column of its own. Location lives on its links in **`dbo.Tributaries`**:
`Main_Lake_id` is the water body, `Lake_id` the other end, `side` says what the link is:

| side | meaning |
|-----:|---------|
| 1 | link |
| 2 | "throw" (flows through) |
| 4 | inflow into a lake (how `sp_add_tributary` records a tributary of a lake) |
| 8 | outflow from a lake |
| **16** | **source** — where the water body starts |
| **32** | **mouth** — where it drains |
| 64 | joined |

- **Every water body has exactly one side-16 and one side-32 row**: `TR_Lake_INS` creates both on insert, pointing at
  itself as a placeholder; the filtered unique indexes `UK_Tributaries_Source` / `UK_Tributaries_Mouth` allow one each.
  Re-pointing the row (`sp_lake_link_assign`, Editor `EditLakeLink.aspx`) makes `TR_UPD_Tributaries` set
  `lake.source` / `lake.mouth`. So `lake.mouth` = the water body it drains into.
- The source/mouth row carries `lat`, `lon`, `elevation` (m), `Country`, `State`, county, city, district, region,
  municipality, zone. `TR_UPD_Tributaries` fills `Country` from a Canadian province code, else `US`. `city` is the
  nearest `dbo.City` place within 10 km where none was given; the mouth row's `road` is the nearest named road within
  10 km (NRCan National Road Network / US Census TIGER).
- **"In a state" means the source OR the mouth is there** (`fn_fish_water_bodies_json`, `fn_river_search_json`). A
  river rising in one province and ending in another is in both. `vw_lake` *reports* country/state source-first.
- `lake.geom` is a **point** (the label point), not a shape. Coordinates for ends come from Tributaries.
- Tributaries (what flows *into* a water body): `dbo.fn_lake_inflows_json` — its side-32 rows pointing here, plus
  side-4 rows a lake holds.

Indexes worth knowing: `UK_Tributaries_Source` / `UK_Tributaries_Mouth` (`Main_Lake_id, side`, filtered),
`IDX_Tributaries_region` (`State, Country` where side 16/32; 2026-10-18). Filtered indexes need
`QUOTED_IDENTIFIER ON` — sqlcmd needs `-I`, or writes fail with Msg 1934 and reads ignore the index.

## Shape: `dbo.Lake_Shape`

Geography rows per water body: `Lake_Shape_type` **1 = river centre line**, **2 = water-body outline** (both from the
Canadian Hydrospatial Network / provincial hydro), NULL = legacy line. `Lake_Shape_hash` is unique and filled by the
trigger *after* the insert, so insert one shape per statement. `fn_lake_shape_geojson` serves them to the river map.
`STLength()` of the type-1 line is a river's length in metres (`lengthM` in search results) — it can be shorter than
the true river when only part is mapped (Saint John River: line 366 km, `length` 673 km).

## Measures and units

| column | unit | note |
|--------|------|------|
| `length` | km, **int** | whole km: short rivers tie at 0/1; use the centre line for metres |
| `width` | km, int | |
| `depth` | m, int | maximum depth |
| `surface` | km², int | called `area` in the APIs |
| `Volume` | km³, int | |
| `Shoreline` | km, int | |
| `Discharge`, `drainage`, `basin`, `watershield` | text | free text, not numbers |
| `Tributaries.elevation` | m | per end; filled from NRCan CDEM where missing (`fill_elevation.py`, 2026-10-16) |

Many rows have NULL or 0 measures; rankings (`sort=length_desc` etc.) leave those out.

## Barriers, stations, fish, regulations

- **Waterfalls and dams**: `dbo.lake_waterfall`, `dbo.lake_dam` (CGNDB / CHN / CABD ids, `lat`/`lon`, link method);
  read with `dbo.fn_lake_barriers_json`.
- **Hydrometric stations**: `dbo.WaterStation` (`MLI` id, `lakeId` = the water body it measures). Search by MLI.
- **Fish**: `dbo.lake_fish` — key `(lake_Id, fish_Id, probability)`, so **one species can have several rows on one
  water body, one per evidence level** (0 science, 2 site owner, 4 paid fishers, 8 unknown fishers, 32/64 pushed from
  other sources) — not duplicates. `status` bitmask: 1 at risk, 2 invasive, 4 special concern, 8 threatened,
  16 non-native. MCP tools show each species once (highest probability) and only to admins.
- **Flags on `lake`**: `isFish` = has ≥1 `lake_fish` row (maintained only by triggers on `lake_fish`; filter on it,
  never decide on it); `noFish` = an editor's claim the water is fishless; `is_fishing_prohibited`; `isWell` = has a
  station; `isolated` = no water connections; `reviewed` = checked by an operator; `ai_edit` bitmask of AI edits.
- **Regulations**: `dbo.regulations`, scoped to one water body (`lakeId`), a zone, a state or a whole country
  (`fn_lake_regulation_json`, `fn_region_regulation_json`). A water body's own rules do not repeat the region's.

## Where the data came from

Canada: CGNDB names/keys everywhere; hydro lines and outlines from CHN (NB/NS), BC Freshwater Atlas (BC), and NHN for
every other province and territory; fish from provincial sources (BC Known Fish Observations, AB, SK Fisheries,
Données Québec, MNR ARA/stocking in Ontario, MB anglers, DFO salmon rivers in NL, GBIF in the north and PEI). USA:
Maine from NHD + GNIS. Per-province notes live in `chn_import/*.md` and `us_import/maine.md` at the project root.

## Known data oddities

- Hudson Bay has `locType` 1, so it ranks as Canada's largest "lake".
- Some rivers exist twice under English and French names (`Mackenzie River`, `Fleuve Mackenzie`).
- Still split on purpose (2026-10-18): **7 features with 3–7 CGNDB keys** — a row holds only two (`CGNDB`, `CGNDM`) —
  Mackenzie River (7 keys: Dehcho, Nagwichoonjik, Kuukpak, Grande Riviere, Fleuve Mackenzie…), Northumberland Strait
  (6), Cabot Strait (4), Strait of Belle Isle (4), Madawaska River (3), Aissimeu-shipu / St. Paul River (3), Churchill
  River NL (3); and **Almstrom Creek** (YT/NT) and **Anderson Creek** (NT/NU), whose two rows are 32–40 km apart and
  do not meet. The review data is in CTRL `nt.dbo.dup_plan` (`status = 'exclude'`).
- ~420 rivers still have a source and mouth at the same point (no open data to fix them; see the river-ends work).
- `iscold` exists only on the local database, not in the schema scripts.

## Where it is used

- **docapi** (`efj-backend/service/docapi`): `/api/v1/river/*` REST endpoints and the **FishFind MCP server**
  (`McpController`, `McpToolCatalog`: `search_water_bodies`, `get_water_body*`, `find_water_bodies_by_fish`).
- **cproxy** (`efc-proxy`): the public gateway in front of docapi; its `docs/api-guide.html` documents the routes.
- **fishfind-frontend**: `Resources/wfRiverViewer.aspx` (public page), `Editor/LakeEditor.aspx`, `EditLakeLink.aspx`,
  `EditLakeFish.aspx`, `LakeRegulation.aspx` (editing).
