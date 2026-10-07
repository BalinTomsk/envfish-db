-- ADMIN_WRITE_lake_state_id_2_search.sql -- ONE-OFF apply for docapi 1.23.0: dbo.fn_river_search_json gains @state_id
-- (6 parameters, was 5). Verbatim copy of its definition in script02_Funct.sql. Delete this file once applied and
-- verified. Needs ADMIN_WRITE_lake_state_id_1_schema.sql first (the column).
-- ORDER: the running docapi 1.22.0 calls the 5-parameter form, so from this moment until docapi 1.23.0 is up every
-- /river/search and MCP search_water_bodies call fails (SQL 313), and 4 failures open docapi's shared sqlBreaker for
-- 30 s. Apply this, then deploy docapi 1.23.0 straight away.
-- Run:  sqlcmd -S <server> -d <docapi database> -E -b -I -i ADMIN_WRITE_lake_state_id_2_search.sql   (or SSMS)
-- Check at the end: params = 6, and the Fraser River row comes back once its state_id is filled (step 3).
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO
IF COL_LENGTH('dbo.Lake', 'state_id') IS NULL
BEGIN
    RAISERROR ('dbo.Lake.state_id is missing: apply ADMIN_WRITE_lake_state_id_1_schema.sql first', 16, 1);
    SET NOEXEC ON;   -- nothing below runs; reconnect (or SET NOEXEC OFF) afterwards
END
GO

IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_river_search_json' AND xtype = 'FN')
    DROP FUNCTION dbo.fn_river_search_json
GO

-- Water-body lookup by any combination of: part of a name, either GUID, either CGNDB code, the
-- provincial/state id, or the MLI of a linked WaterStation. Called by docapi's RiverController
-- (GET /api/v1/river/search) and McpToolCatalog (search_water_bodies) via JdbcRiverQueryRepository.search.
--   @name     - substring of lake_name, alt_name or french_name (case follows the column collation)
--   @guid     - matches lake_id OR secondary_id
--   @cgndb    - matches CGNDB OR CGNDM
--   @state_id - matches state_id exactly (the province's/state's own id, e.g. a BC GNIS id)
--   @mli      - WaterStation.MLI; matches the lake that station is linked to (WaterStation.lakeId)
-- Every supplied criterion must match (AND); NULL/blank criteria are ignored. All NULL -> '[]'.
-- The most selective supplied key drives the lookup (guid, then CGNDB, then state id, then MLI, then
-- name) so only a name-only search scans the table. Order: exact name, then name prefix, then the rest,
-- by lake_name.
-- @limit is clamped to 1..200 (NULL -> 50). Returns a JSON array, '[]' when nothing matches:
--   [{ "lakeId","secondaryId","lakeName","altName","frenchName","locType","CGNDB","CGNDM","stateId",
--      "country","state","mli":["02HC024", ...] }]
-- select dbo.fn_river_search_json(N'Humber', NULL, NULL, NULL, NULL, 10)
-- select dbo.fn_river_search_json(NULL, NULL, 'FEFUL', NULL, NULL, NULL)
-- select dbo.fn_river_search_json(NULL, NULL, NULL, '39325', NULL, NULL)
CREATE FUNCTION dbo.fn_river_search_json( @name nvarchar(64), @guid uniqueidentifier, @cgndb varchar(16)
                                        , @state_id varchar(32), @mli varchar(64), @limit int )
RETURNS nvarchar(max)
AS
BEGIN
    SET @name     = NULLIF(LTRIM(RTRIM(@name)), N'');
    SET @cgndb    = NULLIF(UPPER(LTRIM(RTRIM(@cgndb))), '');
    SET @state_id = NULLIF(LTRIM(RTRIM(@state_id)), '');
    SET @mli      = NULLIF(LTRIM(RTRIM(@mli)), '');
    SET @limit = CASE WHEN @limit IS NULL THEN 50 WHEN @limit < 1 THEN 1 WHEN @limit > 200 THEN 200 ELSE @limit END;

    IF @name IS NULL AND @guid IS NULL AND @cgndb IS NULL AND @state_id IS NULL AND @mli IS NULL
        RETURN N'[]';

    DECLARE @cand TABLE ( lake_id uniqueidentifier NOT NULL PRIMARY KEY );

    IF @guid IS NOT NULL
        INSERT INTO @cand SELECT lake_id FROM dbo.lake WHERE lake_id = @guid
                          UNION
                          SELECT lake_id FROM dbo.lake WHERE secondary_id = @guid;
    ELSE IF @cgndb IS NOT NULL
        INSERT INTO @cand SELECT lake_id FROM dbo.lake WHERE CGNDB = @cgndb
                          UNION
                          SELECT lake_id FROM dbo.lake WHERE CGNDM = @cgndb;
    ELSE IF @state_id IS NOT NULL
        INSERT INTO @cand SELECT lake_id FROM dbo.lake WHERE state_id = @state_id;
    ELSE IF @mli IS NOT NULL
        INSERT INTO @cand SELECT DISTINCT lakeId FROM dbo.WaterStation WHERE MLI = @mli AND lakeId IS NOT NULL;
    ELSE
        INSERT INTO @cand
            SELECT TOP (@limit) lake_id FROM dbo.lake
             WHERE CHARINDEX(@name, lake_name) > 0 OR CHARINDEX(@name, alt_name) > 0 OR CHARINDEX(@name, french_name) > 0
             ORDER BY CASE WHEN lake_name = @name THEN 0 WHEN LEFT(lake_name, LEN(@name)) = @name THEN 1 ELSE 2 END, lake_name;

    DECLARE @hit TABLE ( lake_id uniqueidentifier NOT NULL PRIMARY KEY, irank int NOT NULL, lake_name nvarchar(64) NOT NULL );

    INSERT INTO @hit
        SELECT TOP (@limit) l.lake_id
             , CASE WHEN @name IS NULL OR l.lake_name = @name THEN 0 WHEN LEFT(l.lake_name, LEN(@name)) = @name THEN 1 ELSE 2 END
             , l.lake_name
          FROM @cand c JOIN dbo.lake l ON l.lake_id = c.lake_id
         WHERE (@guid  IS NULL OR @guid IN (l.lake_id, l.secondary_id))
           AND (@cgndb IS NULL OR @cgndb IN (l.CGNDB, l.CGNDM))
           AND (@state_id IS NULL OR l.state_id = @state_id)
           AND (@mli   IS NULL OR EXISTS (SELECT 1 FROM dbo.WaterStation w WHERE w.MLI = @mli AND w.lakeId = l.lake_id))
           AND (@name  IS NULL OR CHARINDEX(@name, l.lake_name) > 0 OR CHARINDEX(@name, l.alt_name) > 0 OR CHARINDEX(@name, l.french_name) > 0)
         ORDER BY 2, l.lake_name;

    RETURN ISNULL((
        SELECT l.lake_id         AS lakeId
             , l.secondary_id    AS secondaryId
             , l.lake_name       AS lakeName
             , l.alt_name        AS altName
             , l.french_name     AS frenchName
             , l.locType         AS locType
             , RTRIM(l.CGNDB)    AS [CGNDB]
             , RTRIM(l.CGNDM)    AS [CGNDM]
             , l.state_id        AS stateId
             , v.country         AS country
             , v.state           AS state
             , JSON_QUERY(ISNULL((SELECT N'[' + STRING_AGG(N'"' + STRING_ESCAPE(w.MLI, 'json') + N'"', N',') WITHIN GROUP (ORDER BY w.MLI) + N']'
                                    FROM dbo.WaterStation w WHERE w.lakeId = l.lake_id), N'[]')) AS mli
          FROM @hit h
          JOIN dbo.lake l ON l.lake_id = h.lake_id
          OUTER APPLY (SELECT TOP 1 vl.country, vl.state FROM dbo.vw_lake vl WHERE vl.lake_id = h.lake_id) v
         ORDER BY h.irank, h.lake_name
        FOR JSON PATH, INCLUDE_NULL_VALUES
    ), N'[]');
END
GO

SELECT DB_NAME() AS db
     , (SELECT COUNT(*) FROM sys.parameters WHERE object_id = OBJECT_ID('dbo.fn_river_search_json') AND parameter_id > 0) AS params
     , dbo.fn_river_search_json(NULL, NULL, NULL, '39325', NULL, 5) AS fraser_by_state_id;
GO
