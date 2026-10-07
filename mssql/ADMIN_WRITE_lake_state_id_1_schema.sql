-- ADMIN_WRITE_lake_state_id_1_schema.sql -- ONE-OFF schema apply for Lake.state_id (the "State ID" box under Mouth on
-- Editor/LakeEditor.aspx). Delete this file once applied and verified; the definitions stay in script01/script02.
-- Adds dbo.Lake.state_id varchar(32) + IX_lake_state_id, and re-creates (verbatim copies of script02_Funct/Proc.sql):
--   SearchLakeList             - the site search also finds a water body by its state_id
--   fn_lake_edit               - state_id attribute for LakeEditor.aspx
--   fn_lake_description_json   - "stateId" (docapi /river/description, MCP get_water_body, the editor's Save JSON)
--   fn_lake_view_json          - "stateId" (public View tab)
--   sp_lake_description_update - "stateId" is patchable (docapi PATCH /river/description)
-- Safe with the running docapi 1.22.0 and the current FishTracker.dll (no signature changes); it must be applied
-- BEFORE the new FishTracker.dll, which saves state_id. Re-runnable.
-- Run:  sqlcmd -S <server> -d <docapi database> -E -b -I -i ADMIN_WRITE_lake_state_id_1_schema.sql   (or SSMS)
-- Then check the SELECT at the end: has_column = 1, has_index = 1, and the five objects not NULL.
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO
IF COL_LENGTH('dbo.Lake', 'state_id') IS NULL
    ALTER TABLE dbo.Lake ADD state_id varchar(32) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.Lake') AND name = 'IX_lake_state_id')
    CREATE NONCLUSTERED INDEX IX_lake_state_id ON dbo.Lake (state_id) WHERE state_id IS NOT NULL;
GO

IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'SearchLakeList' AND xtype = 'TF')
    DROP function dbo.SearchLakeList
GO

-- select * from dbo.SearchLakeList( 'Tim Lake' )
-- select * from dbo.SearchLakeList( '0c5210db849c20c357f421ff96a2047b' )
CREATE FUNCTION dbo.SearchLakeList( @search sysname )
  RETURNS @rst TABLE ( num int NOT NULL identity primary key, lake_name nvarchar(64), irank int, alt_name nvarchar(64), lake_id uniqueidentifier, locType int
                     , country char(2), state char(2), county nvarchar(64)
                     , source_name nvarchar(64) , mouth_name nvarchar(64), [description] nvarchar(1024)
                     , source_lat float, source_lon float, source uniqueidentifier, mouth uniqueidentifier
                     , zone int, isWell bit, isFish bit, source_state char(2), mouth_state char(2)
                     , source_country char(2), mouth_country char(2), mouth_lat float, mouth_lon float
                     , source_loc nvarchar(2048), mouth_loc nvarchar(2048), CGNDB varchar(32))
    AS
begin
    set @search = dbo.NormalizeSearch( @search ) -- remove garbige symbols from search string

    declare  @resultid TABLE ( lake_id uniqueidentifier not null, irank int )

	declare @comb TABLE( line sysname, irank int ); 
	INSERT INTO @comb SELECT line, irank FROM dbo.ProduceSearchVariant( @search )

	IF TRY_CONVERT(UNIQUEIDENTIFIER, dbo.fn_CvtHexToGuid( @search )) IS NOT NULL
		SET @search = dbo.fn_CvtHexToGuid( @search )

	-- a GUID matches the lake's own id OR its secondary_id (edited under GUID on Editor/LakeEditor.aspx)
	IF TRY_CONVERT(UNIQUEIDENTIFIER, @search ) IS NOT NULL
        insert into @resultid (lake_id, irank)
            SELECT @search, 0
            UNION
            SELECT lake_id, 0 FROM dbo.lake WHERE secondary_id = TRY_CONVERT(UNIQUEIDENTIFIER, @search)

    IF NOT EXISTS (SELECT * FROM @resultid)    
    BEGIN
        insert into @resultid (lake_id, irank)
           select DISTINCT lake_id, 0 from dbo.lake l where @search IN (CGNDB, CGNDM, state_id)

        IF NOT EXISTS (SELECT * FROM @resultid)    
        BEGIN
            insert into @resultid (lake_id, irank)
               select lake_id, irank from dbo.lake l WITH (INDEX (idx_Lake_alt_name)) JOIN @comb c ON c.line = alt_name

            insert into @resultid (lake_id, irank)
               select lake_id, irank from dbo.lake l WITH (INDEX (idx_Lake_name)) JOIN @comb c ON c.line = lake_name  

            insert into @resultid (lake_id, irank)
               select lake_id, irank from dbo.lake l WITH (INDEX (idx_Lake_french_name)) JOIN @comb c ON c.line = french_name

            insert into @resultid (lake_id, irank)
               select lake_id, irank from dbo.lake l WITH (INDEX (idx_Lake_native)) JOIN @comb c ON c.line = [native] 

            IF NOT EXISTS (SELECT * FROM @resultid)    
            BEGIN
                insert into @resultid (lake_id, irank)
                   select DISTINCT lake_id, 3 from dbo.lake l where lake_name like N'%' + @search + N'%'

                insert into @resultid (lake_id, irank)
                   select DISTINCT lake_id, 3 from dbo.lake l where alt_name like N'%' + @search + N'%' AND alt_name IS NOT NULL
            END
        END
    END
    delete x from (  select lake_id, rn=row_number() over (partition by lake_id order by irank)  from @resultid) x where rn > 1;

    INSERT INTO @rst SELECT lake_name, irank, alt_name, l.lake_id, locType
        , country, state, county, source_name, mouth_name
        , CASE WHEN county IS NULL THEN state ELSE county END AS [description]
        , lat, lon, null, null, zone, isWell, isFish
        , source_state, mouth_state, source_country, mouth_country
        , mouth_lat, mouth_lon, source_loc, mouth_loc, CGNDB
        FROM vw_lake l JOIN @resultid r ON  r.lake_id = l.lake_id
   RETURN
end
GO

IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_lake_edit' AND xtype = 'FN')
    DROP function dbo.fn_lake_edit ;
GO
/******
 * get description data related to lake
 * used for lake editor
 *
 * INPUT PARAMETERS:
 *    @lake uniqueidentifier        -- lake id
 *
 *    Usage:    
                SELECT dbo.fn_lake_edit('982070AB-BBE4-11D8-92E2-080020A0F4C9')
                SELECT dbo.fn_lake_edit('29efd95b-c6be-11d8-92e2-080020a0f4c9');
                select * from lake where lake_id = '1EB8EABC-BE3C-11D8-92E2-080020A0F4C9'
                UPDATE lake SET isFish = 0 where lake_id = '1EB8EABC-BE3C-11D8-92E2-080020A0F4C9'
 */
CREATE function dbo.fn_lake_edit(@lake_id uniqueidentifier)
RETURNS nvarchar(max)
AS
BEGIN
    DECLARE @main nvarchar(max), @name sysname, @native nvarchar(255), @french_name nvarchar(255), @former_name nvarchar(255), @spanish_name nvarchar(255), @original_name nvarchar(255), @lake_road_access nvarchar(255)
        , @source_name nvarchar(255), @mouth_name nvarchar(255), @fish nvarchar(max), @descript nvarchar(max), @link nvarchar(2048)
        , @drainage nvarchar(128), @discharge nvarchar(128), @watershield nvarchar(128), @fishing nvarchar(max), @alt_name nvarchar(64)
        , @src_id uniqueidentifier, @mth_id uniqueidentifier
    ;WITH cte AS
    (
        SELECT l.lake_id, l.lake_name, l.alt_name, l.[native], l.french_name, l.former_name, l.spanish_name, l.original_name
        , l.stamp, l.locType, l.link, l.depth, l.width, l.length, l.volume
        -- is_fish is read live from lake_fish, NOT from the cached l.isFish flag: the editor uses it to
        -- enable/disable the No Fish checkbox, so it must match what the Fish tab actually holds even if
        -- the cached flag has drifted on a legacy row
        , CASE WHEN EXISTS (SELECT 1 FROM dbo.lake_fish lf WHERE lf.lake_id = l.lake_id) THEN 1 ELSE 0 END AS isFish
        , l.noFish, l.isolated, l.is_fishing_prohibited, l.sid, l.drainage, l.discharge, l.watershield, l.basin
        , l.surface, l.shoreline, l.lake_road_access, l.CGNDB, l.CGNDM, l.state_id, l.secondary_id, l.descript, l.fishing
        , w.source_name, w.mouth_name, w.source_state, w.source_country, l.source, l.mouth, l.reviewed
      FROM dbo.lake l JOIN dbo.vw_lake w ON l.lake_id=w.lake_id WHERE w.lake_id = @lake_id
    )
    SELECT @main = val, @name = lake_name, @native = [native], @french_name = french_name, @former_name = former_name, @spanish_name = spanish_name, @original_name = original_name, @descript = descript
         , @lake_road_access = lake_road_access, @source_name = source_name, @mouth_name = mouth_name, @link = link
         , @drainage = drainage, @discharge = discharge, @watershield = watershield, @fishing = fishing, @alt_name = alt_name
         , @src_id = source, @mth_id = mouth
         FROM
    (
        SELECT * FROM
        (
            SELECT lake_id, secondary_id, stamp, locType, depth, width, length, volume, surface, shoreline, CGNDB, CGNDM, state_id, source_state, source_country
                 , COALESCE(isfish, 0) AS is_fish, COALESCE(noFish, 0) AS no_fish, lake_road_access
                 , COALESCE(is_fishing_prohibited, 0) AS is_fishing_prohibited, COALESCE(reviewed, 0) AS reviewed
                 , isolated, link, basin, sid, drainage, discharge, watershield, fishing, source, mouth
                 FROM cte
        ) t FOR XML RAW ('lake')
    ) x(val), cte;

    SELECT  @fish = COALESCE(val, '') FROM
    ( 
        SELECT * FROM
        (
            SELECT l.fish_id, fish_name FROM lake_fish l JOIN fish f  ON l.fish_id = f.fish_id WHERE lake_id = @lake_id
        ) t FOR XML RAW ('fish')
    ) x(val)

    DECLARE @vals nvarchar(max) = (SELECT STRING_AGG(mli, ',') FROM WaterStation WHERE lakeid=@lake_id);
    IF @vals IS NULL
    BEGIN
        SET @vals = '';
    END
    RETURN '<?xml version="1.0"?><root>' + @main
        + dbo.fn_data2cdata(N'node', N'lake_name',        null,     @name )
        + dbo.fn_data2cdata(N'node', N'native',           null,     @native )
        + dbo.fn_data2cdata(N'node', N'french_name',      null,     @french_name )
        + dbo.fn_data2cdata(N'node', N'former_name',      null,     @former_name )
        + dbo.fn_data2cdata(N'node', N'spanish_name',     null,     @spanish_name )
        + dbo.fn_data2cdata(N'node', N'original_name',    null,     @original_name )
        + dbo.fn_data2cdata(N'node', N'lake_road_access', null,     @lake_road_access )
        + dbo.fn_data2cdata(N'node', N'source_name',      @src_id,  @source_name ) 
        + dbo.fn_data2cdata(N'node', N'mouth_name',       @mth_id,  @mouth_name )
        + dbo.fn_data2cdata(N'node', N'descript',         null,     @descript )    
        + dbo.fn_data2cdata(N'node', N'link',             null,     @link )
        + dbo.fn_data2cdata(N'node', N'drainage',         null,     @drainage )    
        + dbo.fn_data2cdata(N'node', N'discharge',        null,     @discharge )
        + dbo.fn_data2cdata(N'node', N'watershield',      null,     @watershield ) 
        + dbo.fn_data2cdata(N'node', N'fishing',          null,     @fishing )
        + dbo.fn_data2cdata(N'node',  N'alt_name',        null,     @alt_name )
        + N'<tributary>' + dbo.fn_xml_tributary(@lake_id , 0) + N'</tributary>'
        + N'<fish>' + @fish + N'</fish>'
        + CASE WHEN NULLIF(@vals, '') IS NULL THEN '' ELSE '<node name="MLI">' + @vals + '</node>' END
        + '</root>';
END
GO

IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_lake_description_json' AND xtype = 'FN')
    DROP function dbo.fn_lake_description_json
GO
-- fn_lake_description_json : the Description tab (LakeEditor.aspx) — every editable field PLUS the
-- photo gallery, each picture's bytes embedded as base64.
-- Unlike dbo.fn_lake_edit (which INNER JOINs vw_lake and so only sees lakes that have their
-- source/mouth Tributaries placeholders) this LEFT JOINs vw_lake: the core fields always come back
-- from dbo.lake, and source_name/mouth_name are simply null when vw_lake has no row.
CREATE FUNCTION dbo.fn_lake_description_json( @lake_id uniqueidentifier )
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @mli nvarchar(max) =
        (SELECT STRING_AGG(CONVERT(nvarchar(50), mli), ',') FROM dbo.WaterStation WHERE lakeid = @lake_id);
    RETURN
    (
        SELECT TOP 1
            CONVERT(varchar(36), l.lake_id)          AS guid,
            CONVERT(varchar(36), l.secondary_id)     AS secondaryGuid,
            l.lake_name                              AS lakeName,
            l.alt_name                               AS altName,
            l.[native]                               AS nativeName,
            l.french_name                            AS french,
            w.source_name                            AS source,
            CONVERT(varchar(36), l.source)           AS sourceId,
            w.mouth_name                             AS mouth,
            CONVERT(varchar(36), l.mouth)            AS mouthId,
            l.link                                   AS link,
            l.locType                                AS type,
            l.length                                 AS length_km,
            l.width                                  AS width_km,
            l.shoreline                              AS shoreline_km,
            l.depth                                  AS maxDepth_m,
            l.volume                                 AS volume_km3,
            l.surface                                AS surface_km2,
            l.discharge                              AS discharge_m3s,
            l.basin                                  AS basin_km2,
            l.watershield                            AS watershield_km2,
            l.drainage                               AS drainage,
            l.CGNDB                                  AS cgndb,
            l.CGNDM                                  AS cgndm,
            l.state_id                               AS stateId,
            l.lake_road_access                       AS roadAccess,
            @mli                                     AS mli,
            CAST(COALESCE(l.is_fishing_prohibited, 0) AS bit) AS fishingProhibited,
            CAST(COALESCE(l.isolated, 0) AS bit)     AS isolated,
            CAST(COALESCE(l.noFish, 0) AS bit)       AS noFish,
            CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.lake_fish lf WHERE lf.lake_id = l.lake_id)
                      THEN 1 ELSE 0 END AS bit)      AS isFish,
            CAST(COALESCE(l.reviewed, 0) AS bit)     AS reviewed,
            l.descript                               AS description,
            CONVERT(varchar(19), l.stamp, 126)       AS stamp,
            -- photo gallery: metadata + the picture bytes base64-embedded; always an array (never null)
            JSON_QUERY(ISNULL((
                SELECT
                    i.lake_image_id                              AS id,
                    i.lake_image_source                          AS source,
                    i.lake_image_author                          AS author,
                    i.lake_image_link                            AS link,
                    i.lake_image_label                           AS label,
                    i.lake_image_lat                             AS lat,
                    i.lake_image_lon                             AS lon,
                    i.lake_image_type                            AS type,
                    CONVERT(varchar(10), i.lake_image_stamp, 23) AS date,
                    i.lake_image_pic                             AS pic
                FROM dbo.lake_image i
                WHERE i.lake_image_ownerid = l.lake_id
                ORDER BY i.lake_image_stamp
                FOR JSON PATH, INCLUDE_NULL_VALUES
            ), N'[]'))                                AS images
        FROM dbo.lake l
        LEFT JOIN dbo.vw_lake w ON w.lake_id = l.lake_id
        WHERE l.lake_id = @lake_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
    );
END
GO

IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_lake_view_json' AND xtype = 'FN')
    DROP function dbo.fn_lake_view_json
GO
-- fn_lake_view_json : the View tab (Resources/wfRiverViewer.aspx, public read-only) — the composed
-- river-view data: the vw_lake row (source/mouth detail + resolved location) plus the assigned fish
-- and the photo gallery (base64). Anchored on dbo.lake, so vw_lake columns are null for a water body
-- lacking its source/mouth Tributaries placeholders, but the core still exports.
CREATE FUNCTION dbo.fn_lake_view_json( @lake_id uniqueidentifier )
RETURNS NVARCHAR(MAX)
AS
BEGIN
    RETURN
    (
        SELECT TOP 1
            CONVERT(varchar(36), l.lake_id) AS guid,
            l.lake_name                     AS lakeName,
            v.alt_name                      AS altName,
            v.native_name                   AS nativeName,
            v.french_name                   AS french,
            l.locType                       AS type,
            l.descript                      AS description,
            l.link                          AS link,
            l.CGNDB                         AS cgndb,
            l.state_id                      AS stateId,
            l.basin                         AS basin,
            l.watershield                   AS watershield,
            l.drainage                      AS drainage,
            l.discharge                     AS discharge,
            l.length                        AS length_km,
            l.width                         AS width_km,
            l.depth                         AS maxDepth_m,
            l.volume                        AS volume_km3,
            l.surface                       AS surface_km2,
            l.shoreline                     AS shoreline_km,
            v.source_name                   AS sourceName,
            CONVERT(varchar(36), v.source_id) AS sourceId,
            v.source_Lat                    AS sourceLat,
            v.source_Lon                    AS sourceLon,
            v.source_Elevation              AS sourceElevation,
            v.source_state                  AS sourceState,
            v.source_country                AS sourceCountry,
            v.source_location               AS sourceLocation,
            v.mouth_name                    AS mouthName,
            CONVERT(varchar(36), v.mouth_id) AS mouthId,
            v.mouth_Lat                     AS mouthLat,
            v.mouth_Lon                     AS mouthLon,
            v.mouth_Elevation               AS mouthElevation,
            v.mouth_state                   AS mouthState,
            v.mouth_country                 AS mouthCountry,
            v.mouth_location                AS mouthLocation,
            v.lat                           AS lat,
            v.lon                           AS lon,
            v.city                          AS city,
            v.county                        AS county,
            v.state                         AS state,
            v.country                       AS country,
            v.region                        AS region,
            v.district                      AS district,
            v.municipality                  AS municipality,
            v.zone                          AS zone,
            v.location                      AS location,
            JSON_QUERY(ISNULL((
                SELECT
                    CONVERT(varchar(36), lf.fish_id) AS fishId,
                    f.fish_name                      AS fishName,
                    lf.status                        AS status
                FROM dbo.lake_fish lf
                LEFT JOIN dbo.fish f ON f.fish_id = lf.fish_id
                WHERE lf.lake_id = l.lake_id
                ORDER BY f.fish_name
                FOR JSON PATH, INCLUDE_NULL_VALUES
            ), N'[]')) AS fish,
            JSON_QUERY(ISNULL((
                SELECT
                    i.lake_image_id                              AS id,
                    i.lake_image_source                          AS source,
                    i.lake_image_author                          AS author,
                    i.lake_image_link                            AS link,
                    CONVERT(varchar(10), i.lake_image_stamp, 23) AS date,
                    i.lake_image_pic                             AS pic
                FROM dbo.lake_image i
                WHERE i.lake_image_ownerid = l.lake_id
                ORDER BY i.lake_image_stamp
                FOR JSON PATH, INCLUDE_NULL_VALUES
            ), N'[]')) AS images
        FROM dbo.lake l
        LEFT JOIN dbo.vw_lake v ON v.lake_id = l.lake_id
        WHERE l.lake_id = @lake_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
    );
END
GO

IF EXISTS (SELECT * FROM sys.procedures WHERE NAME = 'sp_lake_description_update' AND type = 'P')
    DROP PROCEDURE dbo.sp_lake_description_update
GO
CREATE PROCEDURE dbo.sp_lake_description_update
    @lake_id uniqueidentifier,
    @patch   nvarchar(max)
WITH EXEC AS CALLER
AS
SET NOCOUNT ON
BEGIN TRY
    IF NOT EXISTS (SELECT 1 FROM dbo.lake WHERE lake_id = @lake_id)
    BEGIN
        SELECT CAST(NULL AS nvarchar(max)) AS results;
        RETURN;
    END
    IF @patch IS NULL OR ISJSON(@patch) = 0
    BEGIN
        SELECT (SELECT CONVERT(varchar(36), @lake_id) AS lakeId,
                       JSON_QUERY('[]') AS updated, JSON_QUERY('[]') AS ignored,
                       JSON_QUERY('[{"field":"$","reason":"body is not well-formed JSON"}]') AS protectedFields
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS results;
        RETURN;
    END

    -- SQL Server does not allow a subquery inside an inline DECLARE @v = ... initializer, so @hasFish
    -- is declared then assigned in a separate SET.
    DECLARE @hasFish bit;
    SET @hasFish = CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.lake_fish WHERE lake_id = @lake_id)
                              THEN 1 ELSE 0 END AS bit);
    DECLARE @noFishGiven bit = CASE WHEN JSON_PATH_EXISTS(@patch, '$.noFish') = 1 THEN 1 ELSE 0 END;
    DECLARE @noFishValue bit = TRY_CONVERT(bit, JSON_VALUE(@patch, '$.noFish'));
    DECLARE @noFishBlocked bit = CASE WHEN @noFishGiven = 1 AND @noFishValue = 1 AND @hasFish = 1
                                       THEN 1 ELSE 0 END;

    UPDATE dbo.lake SET
        alt_name         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.altName')       = 1 THEN JSON_VALUE(@patch, '$.altName')       ELSE alt_name END,
        [native]         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.nativeName')    = 1 THEN JSON_VALUE(@patch, '$.nativeName')    ELSE [native] END,
        french_name      = CASE WHEN JSON_PATH_EXISTS(@patch, '$.french')        = 1 THEN JSON_VALUE(@patch, '$.french')        ELSE french_name END,
        link             = CASE WHEN JSON_PATH_EXISTS(@patch, '$.link')          = 1 THEN JSON_VALUE(@patch, '$.link')          ELSE link END,
        locType          = CASE WHEN JSON_PATH_EXISTS(@patch, '$.type')          = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.type'))          ELSE locType END,
        length           = CASE WHEN JSON_PATH_EXISTS(@patch, '$.length_km')     = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.length_km'))     ELSE length END,
        width            = CASE WHEN JSON_PATH_EXISTS(@patch, '$.width_km')      = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.width_km'))      ELSE width END,
        Shoreline        = CASE WHEN JSON_PATH_EXISTS(@patch, '$.shoreline_km')  = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.shoreline_km'))  ELSE Shoreline END,
        depth            = CASE WHEN JSON_PATH_EXISTS(@patch, '$.maxDepth_m')    = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.maxDepth_m'))    ELSE depth END,
        Volume           = CASE WHEN JSON_PATH_EXISTS(@patch, '$.volume_km3')    = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.volume_km3'))    ELSE Volume END,
        surface          = CASE WHEN JSON_PATH_EXISTS(@patch, '$.surface_km2')   = 1 THEN TRY_CONVERT(int, JSON_VALUE(@patch, '$.surface_km2'))   ELSE surface END,
        Discharge        = CASE WHEN JSON_PATH_EXISTS(@patch, '$.discharge_m3s') = 1 THEN JSON_VALUE(@patch, '$.discharge_m3s') ELSE Discharge END,
        basin            = CASE WHEN JSON_PATH_EXISTS(@patch, '$.basin_km2')     = 1 THEN JSON_VALUE(@patch, '$.basin_km2')     ELSE basin END,
        watershield      = CASE WHEN JSON_PATH_EXISTS(@patch, '$.watershield_km2') = 1 THEN JSON_VALUE(@patch, '$.watershield_km2') ELSE watershield END,
        drainage         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.drainage')      = 1 THEN JSON_VALUE(@patch, '$.drainage')      ELSE drainage END,
        CGNDB            = CASE WHEN JSON_PATH_EXISTS(@patch, '$.cgndb')         = 1 THEN JSON_VALUE(@patch, '$.cgndb')         ELSE CGNDB END,
        state_id         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.stateId')       = 1 THEN NULLIF(LTRIM(RTRIM(JSON_VALUE(@patch, '$.stateId'))), '') ELSE state_id END,
        lake_road_access = CASE WHEN JSON_PATH_EXISTS(@patch, '$.roadAccess')    = 1 THEN JSON_VALUE(@patch, '$.roadAccess')    ELSE lake_road_access END,
        is_fishing_prohibited = CASE WHEN JSON_PATH_EXISTS(@patch, '$.fishingProhibited') = 1 THEN TRY_CONVERT(bit, JSON_VALUE(@patch, '$.fishingProhibited')) ELSE is_fishing_prohibited END,
        isolated         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.isolated')      = 1 THEN TRY_CONVERT(bit, JSON_VALUE(@patch, '$.isolated'))      ELSE isolated END,
        noFish           = CASE WHEN @noFishGiven = 1 AND @noFishBlocked = 0 THEN @noFishValue ELSE noFish END,
        reviewed         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.reviewed')      = 1 THEN TRY_CONVERT(bit, JSON_VALUE(@patch, '$.reviewed'))      ELSE reviewed END,
        descript         = CASE WHEN JSON_PATH_EXISTS(@patch, '$.description')   = 1 THEN JSON_VALUE(@patch, '$.description')   ELSE descript END
    WHERE lake_id = @lake_id;

    DECLARE @updated TABLE (field nvarchar(50));
    INSERT INTO @updated (field)
    SELECT v.f FROM (VALUES
        ('altName'),('nativeName'),('french'),('link'),('type'),('length_km'),('width_km'),
        ('shoreline_km'),('maxDepth_m'),('volume_km3'),('surface_km2'),('discharge_m3s'),
        ('basin_km2'),('watershield_km2'),('drainage'),('cgndb'),('stateId'),('roadAccess'),
        ('fishingProhibited'),('isolated'),('reviewed'),('description')
    ) AS v(f)
    WHERE JSON_PATH_EXISTS(@patch, '$.' + v.f) = 1;
    IF @noFishGiven = 1 AND @noFishBlocked = 0
        INSERT INTO @updated (field) VALUES ('noFish');

    DECLARE @ignored TABLE (field nvarchar(50), reason nvarchar(200));
    IF @noFishBlocked = 1
        INSERT INTO @ignored (field, reason)
        VALUES ('noFish', 'lake has assigned species -- No Fish cannot be set while species are assigned');

    DECLARE @protectedFields TABLE (field nvarchar(50), reason nvarchar(200));
    INSERT INTO @protectedFields (field, reason)
    SELECT v.f, 'not editable through this endpoint'
    FROM (VALUES ('lakeName'),('guid'),('source'),('sourceId'),('mouth'),('mouthId')) AS v(f)
    WHERE JSON_PATH_EXISTS(@patch, '$.' + v.f) = 1;

    SELECT (
        SELECT
            CONVERT(varchar(36), @lake_id) AS lakeId,
            JSON_QUERY(ISNULL((SELECT field FROM @updated FOR JSON PATH), '[]')) AS updated,
            JSON_QUERY(ISNULL((SELECT field, reason FROM @ignored FOR JSON PATH), '[]')) AS ignored,
            JSON_QUERY(ISNULL((SELECT field, reason FROM @protectedFields FOR JSON PATH), '[]')) AS protectedFields
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    ) AS results;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER()    AS ErrorNumber,    ERROR_SEVERITY() AS ErrorSeverity, ERROR_STATE()   AS ErrorState
         , ERROR_PROCEDURE() AS ErrorProcedure, ERROR_LINE()     AS ErrorLine,     ERROR_MESSAGE() AS ErrorMessage;
END CATCH
GO

SELECT DB_NAME() AS db
     , CASE WHEN COL_LENGTH('dbo.Lake', 'state_id') IS NOT NULL THEN 1 ELSE 0 END AS has_column
     , (SELECT COUNT(*) FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.Lake') AND name = 'IX_lake_state_id') AS has_index
     , OBJECT_ID('dbo.SearchLakeList') AS SearchLakeList, OBJECT_ID('dbo.fn_lake_edit') AS fn_lake_edit
     , OBJECT_ID('dbo.fn_lake_description_json') AS fn_lake_description_json, OBJECT_ID('dbo.fn_lake_view_json') AS fn_lake_view_json
     , OBJECT_ID('dbo.sp_lake_description_update') AS sp_lake_description_update;
GO
