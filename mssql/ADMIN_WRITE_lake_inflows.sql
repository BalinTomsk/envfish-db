-- One-off apply for docapi 1.22.0 (GET /api/v1/river/tributaries/{guid}, MCP get_water_body_tributaries).
-- Creates dbo.fn_lake_inflows_json -- a verbatim copy of its definition in script02_Funct.sql. Re-runnable.
-- Run it against the database docapi uses, then check the three SELECTs at the end BEFORE deploying docapi:
--   db       = docapi's database name
--   check_1  = not NULL (the function exists)
--   check_2  = a JSON document for the Humber River (ON) with total > 0
-- Delete this file once the function is confirmed live (it stays in script02_Funct.sql).
SET QUOTED_IDENTIFIER ON
GO
IF OBJECT_ID('dbo.fn_SubTributary') IS NULL
BEGIN
    RAISERROR ('dbo.fn_SubTributary is missing on this database: apply it from script02_Funct.sql first', 16, 1);
    SET NOEXEC ON;   -- nothing below runs; reconnect (or SET NOEXEC OFF) afterwards
END
GO
--     SELECT dbo.fn_lake_inflows_json('4094E667-BBE3-11D8-92E2-080020A0F4C9', 50);
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_lake_inflows_json' AND xtype = 'FN')
    DROP FUNCTION dbo.fn_lake_inflows_json
GO
-- fn_lake_inflows_json : the water bodies that flow INTO one water body -- the reverse of its own link rows,
-- which fn_lake_tributary_json returns. Called by docapi's RiverController (GET /api/v1/river/tributaries/{guid})
-- and the MCP tool get_water_body_tributaries (McpToolCatalog), both via JdbcRiverQueryRepository.tributaries.
-- An inflow is recorded one of two ways, and each water body is listed once:
--   link 'mouth'  - its mouth (Tributaries side 32) is this water body, read through dbo.fn_SubTributary
--   link 'inflow' - this water body holds a side-4 row for it (how sp_add_tributary records an inflow
--                   on a lake/pond/reservoir); used only when there is no mouth row
-- lat/lon/country/state are those of the junction row. @limit is clamped to 1..200 (NULL -> 50); `total`
-- counts every inflow. Returns NULL for an unknown water body, else
--   {"guid","lakeName","total","limit","tributaries":[{ "lakeId","lakeName","altName","frenchName","locType",
--    "CGNDB","link","lat","lon","country","state" }]}, by name.
CREATE FUNCTION dbo.fn_lake_inflows_json( @lake_id uniqueidentifier, @limit int )
RETURNS nvarchar(max)
AS
BEGIN
    SET @limit = CASE WHEN @limit IS NULL THEN 50 WHEN @limit < 1 THEN 1 WHEN @limit > 200 THEN 200 ELSE @limit END;

    IF NOT EXISTS (SELECT 1 FROM dbo.lake WHERE lake_id = @lake_id)
        RETURN NULL;

    DECLARE @hit TABLE ( lake_id uniqueidentifier NOT NULL PRIMARY KEY, link varchar(8) NOT NULL
                       , lat float NULL, lon float NULL, country char(2) NULL, state char(2) NULL );

    INSERT INTO @hit (lake_id, link, lat, lon, country, state)
        SELECT x.lake_id, 'mouth', x.lat, x.lon, x.country, x.state
          FROM ( SELECT s.Lake_id AS lake_id, s.lat, s.lon, RTRIM(s.country) AS country, RTRIM(s.state) AS state
                      , ROW_NUMBER() OVER (PARTITION BY s.Lake_id ORDER BY s.side, s.id) AS rn
                   FROM dbo.fn_SubTributary(@lake_id) s
                  WHERE (s.side & 32) <> 0 AND s.Lake_id <> @lake_id ) x
         WHERE x.rn = 1;

    INSERT INTO @hit (lake_id, link, lat, lon, country, state)
        SELECT x.lake_id, 'inflow', x.lat, x.lon, x.country, x.state
          FROM ( SELECT t.Lake_id AS lake_id, t.lat, t.lon, RTRIM(t.Country) AS country, RTRIM(t.State) AS state
                      , ROW_NUMBER() OVER (PARTITION BY t.Lake_id ORDER BY t.id) AS rn
                   FROM dbo.Tributaries t
                  WHERE t.Main_Lake_id = @lake_id AND t.side = 4 AND t.Lake_id <> @lake_id ) x
         WHERE x.rn = 1
           AND NOT EXISTS (SELECT 1 FROM @hit h WHERE h.lake_id = x.lake_id);

    RETURN (
        SELECT CONVERT(varchar(36), l.lake_id) AS guid
             , l.lake_name                     AS lakeName
             , (SELECT COUNT(*) FROM @hit h JOIN dbo.lake i ON i.lake_id = h.lake_id) AS total
             , @limit                          AS limit
             , JSON_QUERY(ISNULL((
                   SELECT TOP (@limit)
                          h.lake_id          AS lakeId
                        , i.lake_name        AS lakeName
                        , i.alt_name         AS altName
                        , i.french_name      AS frenchName
                        , i.locType          AS locType
                        , RTRIM(i.CGNDB)     AS [CGNDB]
                        , h.link             AS link
                        , h.lat              AS lat
                        , h.lon              AS lon
                        , h.country          AS country
                        , h.state            AS state
                     FROM @hit h
                     JOIN dbo.lake i ON i.lake_id = h.lake_id
                    ORDER BY i.lake_name, h.lake_id
                      FOR JSON PATH, INCLUDE_NULL_VALUES
               ), N'[]')) AS tributaries
          FROM dbo.lake l
         WHERE l.lake_id = @lake_id
           FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
    );
END
GO
SELECT DB_NAME() AS db, OBJECT_ID('dbo.fn_lake_inflows_json') AS check_1;
SELECT dbo.fn_lake_inflows_json('4094E667-BBE3-11D8-92E2-080020A0F4C9', 5) AS check_2;
GO
