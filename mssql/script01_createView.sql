
-------------------------------------  Lake --------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vGetLake' AND type = 'V')
    DROP VIEW dbo.vGetLake
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_only_river_list' AND xtype = 'IF')
    DROP FUNCTION dbo.fn_only_river_list
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_river_list' AND xtype = 'TF')
    DROP FUNCTION dbo.fn_river_list
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_full_resource_list' AND xtype = 'IF')
    DROP FUNCTION dbo.fn_full_resource_list
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_GetCloseLake' AND type = 'IF')
    DROP FUNCTION dbo.fn_GetCloseLake
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_GetLakeRegulations' AND type = 'IF')
    DROP FUNCTION dbo.fn_GetLakeRegulations
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_GetAllLakeStates' AND type = 'IF')
    DROP FUNCTION dbo.fn_GetAllLakeStates
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_GetAllLakeZones' AND type = 'IF')
    DROP FUNCTION dbo.fn_GetAllLakeZones
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_ViewTributary' AND type = 'TF')
    DROP FUNCTION dbo.fn_ViewTributary
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_river_list' AND type = 'IF')
    DROP FUNCTION dbo.fn_river_list
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_river_sym' AND xtype = 'IF')
    DROP function dbo.fn_river_sym
GO

IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vw_lake' AND type = 'V')
    DROP VIEW dbo.vw_lake
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_CombineLocation' AND xtype = 'FN')
    DROP function dbo.fn_CombineLocation
GO
-- gives suggested fished for LakeFish Editor
-- SELECT dbo.fn_CombineLocation( 'district', 'region', 'municipality', 'county', 'city', 'location' )
-- SELECT dbo.fn_CombineLocation( null, 'region', 'municipality', 'county', 'city', 'location' )
-- SELECT dbo.fn_CombineLocation( null, 'region', null, 'county', null, null )
-- SELECT dbo.fn_CombineLocation( null, 'region', 'region', 'county', null, null )
-- SELECT dbo.fn_CombineLocation( null, null, null, null, null, null )
CREATE function dbo.fn_CombineLocation( @district nvarchar(64), @region nvarchar(64), @municipality nvarchar(64), @county nvarchar(64), @city nvarchar(64), @location nvarchar(64) )
returns sysname
WITH SCHEMABINDING
as
begin
    DECLARE @result nvarchar(2048) = ''

    SELECT @result = @result + '>' + val FROM 
    (
        SELECT val, rn FROM(
            select TOP 6 val, rn=row_number() over (partition by val order by id), id  from  
            (
                SELECT val, id FROM 
                    ( SELECT NULLIF(LTRIM(RTRIM(value)), '') AS val, id 
                        FROM ( VALUES (@district, 1), (@region, 2), (@municipality, 3), (@county, 4), (@city, 5), (@location, 6) )x(value, id) )y
                    WHERE val IS NOT NULL 
            )z ORDER BY id ASC)v WHERE rn = 1
    )y
    RETURN (CASE WHEN @result IS NULL OR LEN(@result) < 2 THEN @result ELSE RIGHT(@result, LEN(@result)-1) END);
END
GO
--------------------------------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_GetCloseLake' AND xtype = 'IF')
    DROP function dbo.fn_GetCloseLake
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_GetLakeRegulations' AND xtype = 'IF')
    DROP function dbo.fn_GetLakeRegulations
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_GetAllLakeStates' AND xtype = 'IF')
    DROP function dbo.fn_GetAllLakeStates
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_GetAllLakeZones' AND xtype = 'IF')
    DROP function dbo.fn_GetAllLakeZones
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_ViewTributary' AND xtype = 'TF')
    DROP function dbo.fn_ViewTributary
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_river_list' AND xtype = 'IF')
    DROP function dbo.fn_river_list
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_river_sym' AND xtype = 'IF')
    DROP function dbo.fn_river_sym
GO

---- SELECT * FROM dbo.vw_lake WHERE lake_id = '45c0706e-d3aa-47eb-80b1-3f4712817916'
---- SELECT * FROM dbo.vw_lake WHERE state='ON' and LEFT(lake_name,1)= 'A'	
---- select * from vw_lake where lake_name = 'Seguin River' AND state='ON' 
---- select * from lake where reviewed = 1
CREATE VIEW dbo.vw_lake
WITH SCHEMABINDING
AS 
    SELECT source_name, mouth_name, isWell, isFish, noFish
        , lake_id, lake_name, symbol
		, CASE WHEN alt_name = lake_name THEN null ELSE alt_name END AS alt_name
		, native_name
		, french_name
		, old_id, length, depth, width, locType
        , basin, watershield, link, locked, editor, descript, Volume, Shoreline, Drainage, surface
        , source_id
        , source_Elevation, source_Lat, source_Lon, source_region, source_municipality, source_location
        , source_state, source_country, source_county, source_city, source_district, source_zone, source_description
        , mouth_id
        , mouth_Elevation, mouth_Lat, mouth_Lon, mouth_region, mouth_municipality, mouth_location
        , mouth_state, mouth_country, mouth_county, mouth_city, mouth_district, mouth_zone, mouth_description
        , lat, lon, city, county, state, country, region, district, municipality, zone, Discharge, fishing, CGNDB
        , lake_image_source, lake_image_author, lake_image_link, lake_image_stamp
        , COALESCE(source_loc, mouth_loc)    AS location, source_loc, mouth_loc
		, IIF(t_stamp > stamp, t_stamp, stamp) AS stamp, road_access, reviewed
        FROM 
    (
     SELECT CASE WHEN l.lake_name <> source.lake_name THEN source.lake_name ELSe NULL END AS source_name
        ,  CASE WHEN l.lake_name <> mouth.lake_name  THEN mouth.lake_name  ELSe NULL END AS mouth_name
        , l.lake_id, l.lake_name, COALESCE(l.alt_name, l.native) AS alt_name, l.old_id, l.length, l.depth, l.width, l.locType
        , l.basin, l.watershield, l.link, l.locked, l.editor, l.descript, l.Volume, l.Shoreline, l.Drainage, l.surface
        , l.Discharge, l.isfish, l.fishing, l.CGNDB, l.native AS native_name, l.isWell, l.symbol
		, CASE WHEN l.french_name = l.lake_name THEN null ELSE l.french_name END AS french_name
        , COALESCE(l.source, CASE WHEN s.lake_id <> l.lake_id THEN s.lake_id ELSE NULL END) AS source_id
        , s.Elevation AS source_Elevation, s.lat AS source_Lat, s.lon AS source_Lon, s.region AS source_region, s.municipality AS source_municipality, s.location AS source_location
        , s.state AS source_state, s.country AS source_country, s.county as source_county, s.city as source_city, s.district as source_district, s.zone as source_zone, s.descript AS source_description
        , COALESCE(l.mouth, CASE WHEN m.lake_id <> l.lake_id THEN m.lake_id ELSE NULL END) AS mouth_id
        , m.Elevation AS mouth_Elevation, m.Lat AS mouth_Lat, m.Lon AS mouth_Lon, m.region AS mouth_region, m.municipality AS mouth_municipality, m.location AS mouth_location
        , m.state AS mouth_state, m.country AS mouth_country, m.county AS mouth_county, m.city AS mouth_city, m.district AS mouth_district, m.zone AS mouth_zone, m.descript AS mouth_description
        , CASE WHEN s.Lat IS NOT NULL AND m.Lat Is NOT NULL THEN ABS(s.Lat-m.Lat) / 2.0 + (CASE WHEN s.Lat < m.Lat THEN s.Lat ELSE m.Lat END) ELSE COALESCE(s.Lat, m.Lat) END AS lat
        , CASE WHEN s.Lon IS NOT NULL AND m.Lon Is NOT NULL THEN ABS(s.Lon-m.Lon) / 2.0 + (CASE WHEN s.Lon < m.Lon THEN s.Lon ELSE m.Lon END) ELSE COALESCE(s.Lon, m.Lon) END AS lon
        , dbo.fn_CombineLocation( s.district, s.region, s.municipality, s.county, s.city, s.location )      AS source_loc
        , dbo.fn_CombineLocation( m.district,  m.region,  m.municipality,  m.county,  m.city,  m.location ) AS mouth_loc
        , COALESCE(RTRIM(s.city),         RTRIM(m.city))     AS city
        , COALESCE(RTRIM(s.county),       RTRIM(m.county))   AS county
        , COALESCE(RTRIM(s.state),        RTRIM(m.state))    AS state
        , COALESCE(RTRIM(s.country),      RTRIM(m.country))  AS country
        , COALESCE(RTRIM(s.region),       RTRIM(m.region))   AS region
        , COALESCE(RTRIM(s.district),     RTRIM(m.district)) AS district
        , COALESCE(RTRIM(s.municipality), RTRIM(m.municipality)) AS municipality
        , COALESCE(RTRIM(s.zone), RTRIM(m.zone)) AS zone
        , i.lake_image_source, i.lake_image_author, i.lake_image_link, i.lake_image_stamp, l.stamp, l.noFish
		, IIF( COALESCE(m.Tributaries_stamp, '20010101') > COALESCE(s.Tributaries_stamp, '20010101') , COALESCE(m.Tributaries_stamp, '20010101'), COALESCE(s.Tributaries_stamp, '20010101')) AS t_stamp
        , CASE WHEN l.lake_road_access In (s.district, m.district) THEN NULL ELSE l.lake_road_access END AS road_access, l.reviewed
        FROM dbo.lake l  
            JOIN dbo.Tributaries m ON m.main_lake_id = l.lake_id AND m.side = 32    -- only single source
            JOIN dbo.Tributaries s ON s.main_lake_id = l.lake_id AND s.side = 16    -- only single mouth
            LEFT JOIN dbo.lake mouth  ON mouth.lake_id  = m.lake_id
            LEFT JOIN dbo.lake source ON source.lake_id = s.lake_id
            LEFT JOIN dbo.lake_image i ON i.lake_image_id =
                (SELECT TOP 1 x.lake_image_id FROM dbo.lake_image x
                  WHERE x.lake_image_ownerid = l.lake_id
                  ORDER BY x.lake_image_stamp DESC, x.lake_image_id DESC)   -- newest photo only: lake_image is many-per-owner (gallery); a plain ownerid join duplicates every lake with >1 photo
   )x
GO
----------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vFishOK' AND type = 'V')
    DROP VIEW dbo.vFishOK
GO

CREATE VIEW dbo.vFishOK AS 
select fish_name, fish_latin, fish_id,
  CASE WHEN CHARINDEX(',', fish_name ) > 0 THEN (LTRIM(RIGHT(fish_name, LEN(fish_name)-CHARINDEX(',', fish_name ) - 1)) + ' ' + RTRIM(LEFT(fish_name, CHARINDEX(',', fish_name )-1)))
   ELSE fish_name END AS name  from fish
GO
-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_get_fish_bylatlon' AND xtype = 'IF')
    DROP FUNCTION dbo.fn_get_fish_bylatlon
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vget_fish_list' AND type = 'V')
    DROP VIEW dbo.vget_fish_list
GO

CREATE VIEW dbo.vget_fish_list
WITH SCHEMABINDING
AS 
  SELECT  fish_Id, fish_name  FROM dbo.FISH 
     WHERE ( fish_Type & 1 ) = 1                   --- sport species
GO
-- select * from dbo.vget_fish_list  order by 2
-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_get_trial_fish_byzip' AND xtype = 'IF')
    DROP FUNCTION dbo.fn_get_trial_fish_byzip
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_get_trial_fish_bylatlon' AND xtype = 'IF')
    DROP FUNCTION dbo.fn_get_trial_fish_bylatlon
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vget_trial_fish_list' AND type = 'V')
    DROP VIEW dbo.vget_trial_fish_list
GO
-- fn_get_trial_fish_bylatlon, fn_get_trial_fish_byzip
-- 1 - sport, 2 - Coarse, 4 - commersial, 8 - invading
CREATE  VIEW dbo.vget_trial_fish_list
WITH SCHEMABINDING
AS 
  SELECT f. fish_Id,  fish_name  
     FROM dbo.fish f JOIN dbo.fish_zoo z ON f.fish_id=z.fish_id
     WHERE NOT ( fish_Type & 1 = 1 OR fish_Type & 2 = 2) AND z.fish_max_length BETWEEN 40 AND 70   
GO
----------------------------------------------------------------------------------------------------------------------------
-- used in water data services
----------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vwWaterStation' AND type = 'V')
    DROP VIEW dbo.[vwWaterStation]
GO

CREATE VIEW [dbo].[vwWaterStation] 
WITH SCHEMABINDING
AS
  SELECT w.mli, w.country, w.state, ISNULL(w.tz,0) AS tz, c.stamp from dbo.WaterStation w LEFT JOIN dbo.CurrentWaterState c ON w.mli = c.mli
      WHERE supported = 1  
GO
------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vMapView' AND type = 'V')
    DROP VIEW dbo.vMapView
GO
-- SELECT  TOP 1000  lat, lon, sid FROM vMapView WHERE country='CA'
-- SELECT  * FROM vMapView WHERE country='US' and cast(stamp as date) > '2020-01-01'


CREATE VIEW dbo.vMapView 
WITH SCHEMABINDING
 AS
	SELECT w.sid, w.lat, w.lon, w.country, w.state, y.stamp FROM dbo.WaterStation w WITH (NOLOCK) 
		JOIN
		(
			SELECT TOP 16024 sid, stamp FROM dbo.CurrentWaterState d WITH (NOLOCK) WHERE stamp > dateadd(day, -15, getdate()) and sid > 0
			UNION
			SELECT sid, stamp FROM (SELECT TOP 16024 sid, stamp FROM dbo.CurrentWaterState d WITH (NOLOCK) WHERE sid > 0 ORDER BY  getdate() DESC)x
		)y ON w.sid=y.sid
		WHERE state NOT IN ('HI', 'PR') 
		--AND EXISTS (SELECT mli FROM [dbo].[WaterData] d WHERE d.mli =w.mli)
GO

------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'GetLastHourWaterData' AND xtype = 'IF')
    DROP function dbo.GetLastHourWaterData
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vScienceView' AND type = 'V')
    DROP VIEW dbo.vScienceView
GO

IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vw_WaterData' AND type = 'V')
    DROP VIEW dbo.vw_WaterData
GO
--- hide internal convertions: PH, airtemp
-- select top 100  * from vw_WaterData where dt > '2021-01-01'
--   select top 100  * from vw_WaterData  where  mli = '02GE004' or  263911 = sid
CREATE VIEW dbo.vw_WaterData
WITH SCHEMABINDING
 AS
    SELECT w.mli, w.state, w.lat, w.lon, w.id, w.sid, w.locName, w.city, w.country, d.stamp
        , CAST(d.stamp AS date) AS dt
		, CAST(CAST(DATEADD(HOUR,w.tz, d.stamp) AS time) AS varchar(8)) AS tm
		, temperature, discharge
        , d.elevation, (CAST(d.ph AS float) / 10.0) AS PH, d.oxygen, d.turbidity, velocity
    FROM dbo.WaterStation w JOIN dbo.WaterData d ON d.mli = w.mli
GO

------------------------------------------------------------------------------
-- select TOP 1 * from dbo.vScienceView WHERE 263911 = sid order by dt desc, tm desc
------------------------------------------------------------------------------

CREATE VIEW dbo.vScienceView 
WITH SCHEMABINDING
 AS
SELECT mli, state, lat, lon, id, sid, locName, city, country, stamp
   , CONVERT(varchar(16), dt, 107) AS dt, CAST(tm AS varchar(5)) AS tm
   , ISNULL( CAST(ROUND(temperature, 1) AS varchar(16)), 'N/A') AS temperature
   , ( CASE WHEN country = 'US' THEN 'F' ELSE 'C' END ) AS temperature_unit
   , ISNULL( CAST(NULLIF(ROUND(discharge, 1), 0) AS varchar(16)), 'N/A') AS discharge
   , ( CASE WHEN country = 'US' THEN 'ft^3/s' ELSE 'm^3/s' END ) AS discharge_unit
   , ISNULL( CAST(ROUND(elevation, 2) AS varchar(16)), 'N/A') AS elevation
   , ( CASE WHEN country = 'US' THEN 'ft' ELSE 'm' END ) AS elevation_unit
   , ISNULL( CAST(ROUND(oxygen, 3) AS varchar(16)), 'N/A') AS oxygen
   , ISNULL( CAST(PH AS varchar(8)), 'N/A') AS ph
   , ISNULL( CAST(ROUND(turbidity, 1) AS varchar(16)), 'N/A') AS turbidity
   , ISNULL( CAST(ROUND(velocity, 1) AS varchar(16)), 'N/A') AS velocity
   , ( CASE WHEN country = 'US' THEN 'ft/s' ELSE 'm/s' END ) AS velocity_unit
   FROM 
   (
     SELECT mli, state, lat, lon, id, sid, locName, city, country, stamp
          , CAST(stamp AS date) AS dt, CAST(stamp AS time) AS tm
        , CASE WHEN country = 'US' THEN 32 + (temperature / 1.8) ELSE temperature END  AS temperature
        , CASE WHEN country = 'US' THEN discharge * 35.314666721489 ELSE discharge END  AS discharge
        , CASE WHEN country = 'US' THEN elevation * 3.28084 ELSE elevation END  AS elevation
        , PH, oxygen, turbidity
        , CASE WHEN country = 'US' THEN velocity * 35.3147 ELSE velocity END  AS velocity
        FROM dbo.vw_WaterData 
    )z
GO
-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vw_editor_fish_food' AND type = 'V')
    DROP VIEW dbo.vw_editor_fish_food
GO

/*
     used in FishTracker.Editor.EditFood.LoadEditedFood()
*/
CREATE VIEW dbo.vw_editor_fish_food
WITH SCHEMABINDING
AS
  SELECT  fish_id, fish_name, fish_latin
        , food_habitat, terrestrial_insects
        , crustaceans, terrestrial_animals 
        , ISNULL(locked, CONVERT(bit, 0)) AS locked
        , node_food_habitat, stamp
        , (select userName from dbo.users where id=editor) AS editor 
  FROM dbo.fish
GO
------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vw_fish_image' AND type = 'V')
    DROP VIEW dbo.vw_fish_image
GO

CREATE VIEW [dbo].vw_fish_image
WITH SCHEMABINDING
AS
  SELECT  f.fish_id, fish_image_gender, fish_image_juvenile, fish_image_pic, fish_image_id, fish_image_source, fish_image_author, fish_image_link, fish_image_label
        , fish_image_tag, fish_image_stamp, fish_image_location, fish_image_lat, fish_image_lon
  FROM dbo.fish f
    LEFT JOIN dbo.fish_image z ON z.fish_Id = f.fish_id
GO
-------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vw_read_fish_spawn' AND type = 'V')
    DROP VIEW dbo.vw_read_fish_spawn
GO

CREATE VIEW dbo.vw_read_fish_spawn
WITH SCHEMABINDING
AS
  SELECT  f.fish_id, f.fish_name, fish_latin, periodStart, periodEnd, r.habitat, r.spawnsOver
         , tu.ri_min AS tuLD , tu.ri_low AS tuL , tu.ri_avg AS tuC , tu.ri_high AS tuH , tu.ri_max AS tuHD 
         , tm.ri_min AS tmLD , tm.ri_low AS tmL , tm.ri_avg AS tmC , tm.ri_high AS tmH , tm.ri_max AS tmHD 
         , ox.ri_min AS oxLD , ox.ri_low AS oxL , ox.ri_avg AS oxC , ox.ri_high AS oxH , ox.ri_max AS oxHD 
         , ph.ri_min AS phLD , ph.ri_low AS phL , ph.ri_avg AS phC , ph.ri_high AS phH , ph.ri_max AS phHD 
         , ve.ri_min AS veL, ve.ri_max AS veH
         , sa.ri_min AS saL, sa.ri_max AS saH
         , ni.ri_min AS niL, ni.ri_max AS niH
         , phosphat.ri_min AS phosphatL, phosphat.ri_max AS phosphatH
         , depth.ri_min AS fish_spawnDepth_min, depth.ri_max AS fish_spawnDepth_max
         , r.locked, r.stamp
         , (select userName from dbo.users where id=r.editor) AS editor 
  FROM dbo.fish f 
    LEFT JOIN dbo.fish_Rule r ON r.fish_Id = f.fish_id 
    LEFT JOIN dbo.real_interval depth ON depth.ri_parent_id = r.id AND depth.ri_type = 2
    LEFT JOIN dbo.real_interval ph ON ph.ri_parent_id = r.id AND ph.ri_type = 8
    LEFT JOIN dbo.real_interval tm ON tm.ri_parent_id = r.id AND tm.ri_type = 16
    LEFT JOIN dbo.real_interval tu ON tu.ri_parent_id = r.id AND tu.ri_type = 24
    LEFT JOIN dbo.real_interval ox ON ox.ri_parent_id = r.id AND ox.ri_type = 32
    LEFT JOIN dbo.real_interval ve ON ve.ri_parent_id = r.id AND ve.ri_type = 40
    LEFT JOIN dbo.real_interval sa ON sa.ri_parent_id = r.id AND sa.ri_type = 48
    LEFT JOIN dbo.real_interval phosphat ON phosphat.ri_parent_id = r.id AND phosphat.ri_type = 56
    LEFT JOIN dbo.real_interval ni ON ni.ri_parent_id = r.id AND ni.ri_type = 64
  WHERE periodStart <> -1 AND periodEnd <> -1
GO
-------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vw_read_fish_zoo' AND type = 'V')
    DROP VIEW dbo.vw_read_fish_zoo
GO

--- select * from [dbo].vw_read_fish_zoo order by stamp desc
CREATE VIEW [dbo].vw_read_fish_zoo
WITH SCHEMABINDING
AS
  SELECT  f.fish_id, f.fish_name, f.fish_latin, 1 AS locked, 'Max' AS editor,
          fish_max_length, fish_avg_length, fish_avg_weight, fish_max_weight, natural_color, fish_zoo_image
        , fin, body, Longevity, coloration, Counts, shape, external_morphology, internal_morphology, z.stamp
  FROM dbo.fish f 
    LEFT JOIN dbo.fish_zoo z ON z.fish_Id = f.fish_id
GO
--select * from vLastCurrentWaterState order by stamp desc
--SELECT * FROM vLastCurrentWaterState
-- SELECT * FROM vCurrentWaterState order by iterstamp desc
GO
-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_map_location_trial' AND xtype = 'IF')
    DROP function dbo.fn_map_location_trial
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_map_location' AND xtype = 'IF')
    DROP function dbo.fn_map_location
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_get_trial_location' AND xtype = 'IF')
    DROP function dbo.fn_get_trial_location
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_map_location_trial' AND xtype = 'IF')
    DROP function dbo.fn_map_location_trial
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'GetLocations' AND xtype = 'TF')
    DROP function dbo.GetLocations
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'GetStationInfo' AND xtype = 'TF')
    DROP function dbo.GetStationInfo
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'GetStation' AND xtype = 'TF')
    DROP function dbo.GetStation
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'GetFisNamePlaceDescr' AND xtype = 'TF')
    DROP function dbo.GetFisNamePlaceDescr
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vWaterStation' AND type = 'V')
    DROP VIEW dbo.vWaterStation
GO
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vWaterStation' AND type = 'V')
    DROP VIEW dbo.vWaterStation
GO

CREATE VIEW dbo.vWaterStation 
WITH SCHEMABINDING
AS
  SELECT id, sid, mli, lat, lon, locType, locName, city, country
       , backoffstate, backoff_daily_503_count, backoff_weekly_503_count, backoff_last_503_date, backoff_next_date
       , [state], County, condition, wheatherStamp, lakeId from dbo.WaterStation
GO
-------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vDefaultNews' AND type = 'V')
    DROP VIEW dbo.vDefaultNews
GO
-- SELECT * FROM dbo.vDefaultNews ORDER BY ORD ASC
-- 5270EACB-96B6-41BD-A92C-1E3A5A634CB9
-- Used in default.aspx
CREATE VIEW dbo.vDefaultNews
AS
    WITH cte AS
    (
        SELECT news_id, 1 AS nn FROM (select TOP 2 news_id from news WHERE news_publish = 1 AND country = 'CA' AND news_photo0 IS NOT NULL ORDER BY news_stamp DESC)x
        UNION
        SELECT news_id, 2 AS nn FROM (select TOP 2 news_id from news WHERE news_publish = 1 AND news_photo0 IS NOT NULL ORDER BY stamp DESC)y
    )
    SELECT TOP 5 news.news_id, news.news_title, news.news_author, news.news_author_link, news.news_source, news.news_source_link
    , CASE WHEN ORD = 1 THEN news.news_photo0 ELSE NULL END AS news_photo0
    , news.news_photo_author0, news.news_paragraph0, news.news_photo_alt0
    , CASE WHEN ORD = 1 THEN news.news_photo1 ELSE NULL END AS news_photo1
    , news.news_photo_author1, news.news_paragraph1, news.news_photo_alt1
    , news.news_stamp, news.stamp, news.country, fish1_id, fish2_id, fish3_id
    , news.lake_id, l.lake_name
         , (SELECT fish_name FROM fish WHERE fish_id = fish1_id) AS fish1_name
         , (SELECT fish_name FROM fish WHERE fish_id = fish2_id) AS fish2_name
         , (SELECT fish_name FROM fish WHERE fish_id = fish3_id) AS fish3_name
         , ORD FROM 
    (
        SELECT news_id, MIN(nn) AS ORD FROM 
        (
            SELECT news_id, nn FROM cte
            UNION
            SELECT news_id, nn FROM 
            (
                SELECT TOP 3 news_id, 3 AS nn FROM (select TOP 3 news_id from news WHERE news_publish = 1 AND country = 'CA' ORDER BY news_stamp DESC)x
                    WHERE NOT EXISTS (SELECT news_id FROM cte WHERE cte.news_id = x.news_id)
                UNION
                SELECT TOP 3 news_id, 4 AS nn FROM (select TOP 3 news_id from news WHERE news_publish = 1 AND country = 'US' ORDER BY news_stamp DESC)y
                    WHERE NOT EXISTS (SELECT news_id FROM cte WHERE cte.news_id = y.news_id)
                UNION
                SELECT TOP 3 news_id, 5 AS nn FROM (select TOP 3 news_id from news WHERE news_publish = 1 AND country NOT IN ( 'US', 'CA') ORDER BY news_stamp DESC)z
                    WHERE NOT EXISTS (SELECT news_id FROM cte WHERE cte.news_id = z.news_id)
            )y
        )k GROUP BY news_id
    )u JOIN news ON u.news_id = news.news_id 
	LEFT JOIN lake l ON l.lake_id = news.lake_id
	ORDER BY ORD ASC
GO
-------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vNewsList' AND type = 'V')
    DROP VIEW dbo.vNewsList
GO
-- select id, news_id, title, source, stamp, flag from vNewsList ORDER BY id DESC
-- Used in default.aspx
CREATE VIEW dbo.vNewsList
AS
    SELECT row_number() over (order by id DESC) AS id, 
	     news.id AS nid, news_id, news_title AS title, news_source AS source
	     , CAST(CAST(news_stamp AS DATE) AS char(10)) AS stamp
         , news_photo0
	     , country AS flag, x.cnt 
	FROM news
		, (SELECT COUNT(*) AS cnt FROM news WHERE news_publish = 1)x
    WHERE news_publish = 1
GO

-------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vwWeatherForecastToDay' AND type = 'V')
    DROP VIEW dbo.vwWeatherForecastToDay
GO

-- select * from [vwWeatherForecastToDay] where country='US'
-- Used in OWMService to get list of waterstations not having current wheather data
-- wheater collectd only for water  bodies with fish and water data
--
-- Callers: efcs-backend service/weather WeatherService.Data.WeatherStationRepository
-- (FindSupportedStationsAsync / CountSupportedStationsAsync), and the Java weather service.
--
-- THE CRITERION IS FISH: a station is collected when its water body has >= 1 assigned species.
-- There is deliberately no water-data condition.
--
-- It used to also require a 15-day window on dbo.ows_meteo.stamp, commented "only if water data
-- exists". That column is NOT a water-data fact: ows_meteo rows are seeded by
-- trg_WaterStation_AI_ows_meteo and thereafter stamp is only ever written by the WEATHER worker
-- itself (WeatherDataRepository: "UPDATE dbo.ows_meteo SET ..., stamp = GETDATE()"). The predicate
-- was therefore self-referential -- it really meant "we collected weather here recently" -- so a
-- station that fell outside the window could never re-enter, because nothing else could ever move
-- its stamp. On prod that had frozen out 46 CA + 12 US fish-bearing stations, still stamped
-- 2021-03-01 with ows IS NULL, 43 of the CA ones with perfectly current water data.
--
-- Note this is intentionally NOT re-expressed as "EXISTS (dbo.WaterData)": that reading of the old
-- comment would DROP 81 CA + 157 US stations that are being collected today but hold no WaterData
-- rows. Fish presence is the rule; water data does not gate it.
-- Covered by UNIT_TESTS/unit_test@WeatherForecastToDay.sql.
CREATE VIEW [dbo].[vwWeatherForecastToDay]
WITH SCHEMABINDING
AS
    WITH cte AS
    (
        SELECT w.mli, w.lat, w.lon, w.country, w.state, w.sid, w.stamp, w.backoffstate
        FROM dbo.WaterStation w
        WHERE EXISTS (select 1 from dbo.lake_fish f where f.lake_Id = w.lakeId)  -- if water body has fishes
    )
    SELECT mli, lat, lon, country, state, sid, stamp, 1 AS flag FROM 
    (
        SELECT mli, lat, lon, country, state, sid, stamp FROM cte 
            WHERE backoffstate = 0
        ORDER BY NEWID() OFFSET 0 ROWS
    ) AS FirstSet
    UNION ALL
    SELECT mli, lat, lon, country, state, sid, stamp, 0 AS flag FROM cte w 
        WHERE backoffstate > 0
            AND NOT EXISTS ( SELECT 1 FROM cte WHERE backoffstate = 0 )
GO
-------------------------------------------------------------------------------------------------------

-----------------------------------------------------------------------------------------------------------------------------------------------
-- RETIRED 2026-08-19 - 17 views dropped from production because nothing referenced them.
-- Verified before removal: no sys.sql_expression_dependencies row, no other module's TEXT mentions
-- them, and no hit anywhere in the 8 repositories under c:\envoinxishfind - all file types,
-- including the compiled bin\*.dll. Their definitions remain in git history (this file, before this
-- commit); the drops below are kept so any other replication node sheds them too.
-- Removing these also cleared duplicate definitions this file carried: vCurrentWaterState was
-- defined 3x and vStationInfo 2x, where the last one silently won.
-- NOTE dbo.vwWeatherForecastToDay is a DIFFERENT view and is very much alive - it is the work list
-- for both weather services. Do not confuse it with vwWeatherForecast below.
-----------------------------------------------------------------------------------------------------------------------------------------------
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_get_koef_fish_station_oxygen' AND type = 'V')
    DROP VIEW dbo.fn_get_koef_fish_station_oxygen ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_get_koef_fish_station_ph' AND type = 'V')
    DROP VIEW dbo.fn_get_koef_fish_station_ph ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_get_koef_fish_station_temperature' AND type = 'V')
    DROP VIEW dbo.fn_get_koef_fish_station_temperature ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_get_koef_fish_station_velocity' AND type = 'V')
    DROP VIEW dbo.fn_get_koef_fish_station_velocity ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vCurrentWaterState' AND type = 'V')
    DROP VIEW dbo.vCurrentWaterState ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vDefaultLastLake' AND type = 'V')
    DROP VIEW dbo.vDefaultLastLake ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vget_fish4push' AND type = 'V')
    DROP VIEW dbo.vget_fish4push ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vGetCurrentWeather' AND type = 'V')
    DROP VIEW dbo.vGetCurrentWeather ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vGetOntarioList' AND type = 'V')
    DROP VIEW dbo.vGetOntarioList ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vLastCurrentWaterState' AND type = 'V')
    DROP VIEW dbo.vLastCurrentWaterState ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vStationInfo' AND type = 'V')
    DROP VIEW dbo.vStationInfo ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vUpdateWaterData' AND type = 'V')
    DROP VIEW dbo.vUpdateWaterData ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vw_fish_spot' AND type = 'V')
    DROP VIEW dbo.vw_fish_spot ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vw_lake_state' AND type = 'V')
    DROP VIEW dbo.vw_lake_state ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vw_plot_weather' AND type = 'V')
    DROP VIEW dbo.vw_plot_weather ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vw_regulations' AND type = 'V')
    DROP VIEW dbo.vw_regulations ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vwWeatherForecast' AND type = 'V')
    DROP VIEW dbo.vwWeatherForecast ;
GO
