
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
        , lat, lon, city, county, state, country, region, district, municipality, zone, Discharge, fishing, CGNDB, CGNDM
        , lake_image_source, lake_image_author, lake_image_link, lake_image_stamp
        , COALESCE(source_loc, mouth_loc)    AS location, source_loc, mouth_loc
		, IIF(t_stamp > stamp, t_stamp, stamp) AS stamp, road_access, reviewed
        FROM 
    (
     SELECT CASE WHEN l.lake_name <> source.lake_name THEN source.lake_name ELSe NULL END AS source_name
        ,  CASE WHEN l.lake_name <> mouth.lake_name  THEN mouth.lake_name  ELSe NULL END AS mouth_name
        , l.lake_id, l.lake_name, COALESCE(l.alt_name, l.native) AS alt_name, l.old_id, l.length, l.depth, l.width, l.locType
        , l.basin, l.watershield, l.link, l.locked, l.editor, l.descript, l.Volume, l.Shoreline, l.Drainage, l.surface
        , l.Discharge, l.isfish, l.fishing, l.CGNDB, l.CGNDM, l.native AS native_name, l.isWell, l.symbol
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

----------------------------------------------------------------------------------------------------------------------------
IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'fn_get_koef_fish_station_temperature' AND xtype = 'V')
    DROP VIEW dbo.fn_get_koef_fish_station_temperature
-- fn_get_koef_fish_station_temperature removed with the water temperature reading (2026-11-08); the DROP above
-- clears it from existing databases.
GO

-- select *  from  dbo.vget_trial_fish_list
-- 1 - sport, 2 - Coarse, 4 - commersial, 8 - invading, 128 - migrate pattern (inverted logic by default)
-------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------

IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vget_fish4push' AND type = 'V')
    DROP VIEW dbo.vget_fish4push
GO

-- used in [spStepPushSpeciesFromLakeToStation]
-- select * from vget_fish4push
CREATE VIEW [dbo].[vget_fish4push]
WITH SCHEMABINDING
AS 
SELECT fish_id, habitat, spawnPeriod, periodStart, periodEnd FROM 
(
    SELECT fish_id, habitat, 0 AS spawnPeriod, periodStart, periodEnd 
    FROM dbo.fish_rule WHERE -1 = periodStart AND -1 = periodEnd
    UNION ALL
    SELECT fish_id, habitat, 1 AS spawnPeriod, periodStart, periodEnd 
    FROM dbo.fish_rule WHERE -1 <> periodStart AND -1 <> periodEnd
)e WHERE spawnPeriod = (CASE WHEN DATEPART( MM, getdate()) BETWEEN periodStart AND periodEnd THEN 1 ELSE 0 END)
GO

-----------------------------------------------------------------------------------------------------------------------------------------------
-- RETIRED 2026-08-19 - 12 views dropped from production because nothing referenced them.
-- (The four fn_get_koef_fish_station_* views and vget_fish4push were part of this set and were
--  REINSTATED above at the owner's request - kept despite having no caller.)
-- Verified before removal: no sys.sql_expression_dependencies row, no other module's TEXT mentions
-- them, and no hit anywhere in the 8 repositories under c:\envoinxishfind - all file types,
-- including the compiled bin\*.dll. Their definitions remain in git history (this file, before this
-- commit); the drops below are kept so any other replication node sheds them too.
-- Removing these also cleared duplicate definitions this file carried: vCurrentWaterState was
-- defined 3x and vStationInfo 2x, where the last one silently won.
-- NOTE dbo.vwWeatherForecastToDay is a DIFFERENT view and is very much alive - it is the work list
-- for both weather services. Do not confuse it with vwWeatherForecast below.
-----------------------------------------------------------------------------------------------------------------------------------------------
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vCurrentWaterState' AND type = 'V')
    DROP VIEW dbo.vCurrentWaterState ;
GO
 IF EXISTS (SELECT * FROM sysobjects WHERE NAME = 'vDefaultLastLake' AND type = 'V')
    DROP VIEW dbo.vDefaultLastLake ;
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
