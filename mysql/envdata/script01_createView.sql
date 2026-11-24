-- envdata/script01_createView.sql: the read surface of the water/weather database.
-- Applications read ONLY these views (and the procedures in script02_Proc.sql), never a table.
-- Views take no parameters: a caller filters them with WHERE; logic that needs a parameter is a procedure.

-- ------------------------------------------------------------------------------------------------------------
-- v_station_water_due: the stations the water collectors process (port of MSSQL vwWaterStation).
-- stamp = the newest reading in station_current (NULL = never read).
-- Called by: waterservice (C#) Data/WaterStationRepository:
--   SELECT mli, state, tz FROM v_station_water_due WHERE country = ? ORDER BY stamp DESC
-- ------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_station_water_due AS
SELECT s.mli, s.country, s.state, COALESCE(s.tz, 0) AS tz, c.ts AS stamp
  FROM station s
  LEFT JOIN station_current c ON c.station_id = s.station_id
 WHERE s.supported = 1;

-- ------------------------------------------------------------------------------------------------------------
-- v_station_weather_due: the stations the weather collectors process (port of MSSQL vwWeatherForecastToDay).
-- THE CRITERION IS FISH: a station is collected when its water body has >= 1 species (station.has_fish, carried
-- from MSSQL lake_fish by the mirror). flag 1 = not in HTTP 503 back-off. Back-off stations (flag 0) are listed
-- only when no fish station at all is free of back-off - the same fallback the MSSQL view has.
-- Called by: weather (C#) Data/WeatherStationRepository, through sp_station_weather_due (random sample) and
--   SELECT COUNT(1) FROM v_station_weather_due WHERE country = ?
-- ------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_station_weather_due AS
SELECT s.mli, s.lat, s.lon, s.country, s.state, s.station_id AS sid, s.master_stamp AS stamp, 1 AS flag
  FROM station s
 WHERE s.has_fish = 1 AND s.backoff_state = 0
UNION ALL
SELECT s.mli, s.lat, s.lon, s.country, s.state, s.station_id AS sid, s.master_stamp AS stamp, 0 AS flag
  FROM station s
 WHERE s.has_fish = 1 AND s.backoff_state > 0
   AND NOT EXISTS (SELECT 1 FROM station x WHERE x.has_fish = 1 AND x.backoff_state = 0);

-- ------------------------------------------------------------------------------------------------------------
-- v_station_503_summary: water stations in HTTP 503 back-off by state and stage (port of
-- sp_water_station_503_summary_by_state's query). Called by: sp_station_503_summary_by_state (operations).
-- ------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_station_503_summary AS
SELECT s.state
     , CASE s.backoff_state WHEN 1 THEN 'DAILY' WHEN 2 THEN 'WEEKLY' WHEN 3 THEN 'MONTHLY' ELSE 'NORMAL' END AS backoff_stage
     , COUNT(*) AS station_count
  FROM station s
 WHERE s.backoff_state <> 0
 GROUP BY s.state, s.backoff_state;

-- ------------------------------------------------------------------------------------------------------------
-- v_weather_gov_station: the cached NWS station per gauge (port of MSSQL fn_weather_gov_station).
-- 0 rows for a mli = never resolved; 1 row with station_id NULL = resolved, nothing nearby.
-- Called by: weather (C#) Data/WeatherGovStationRepository.FindAsync:
--   SELECT station_id FROM v_weather_gov_station WHERE mli = ?
-- ------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_weather_gov_station AS
SELECT s.mli, g.nws_station_id AS station_id, g.lat, g.lon, g.stamp
  FROM weather_gov_station g
  JOIN station s ON s.station_id = g.station_id;

-- ------------------------------------------------------------------------------------------------------------
-- v_provider_coverage: what is known about each provider's coverage of each gauge (port of
-- fn_weather_station_coverage / fn_weather_uncovered_stations). Called by: weather (C#), env_service (status).
-- ------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_provider_coverage AS
SELECT s.mli, s.country, s.state, c.provider, c.covered, c.stamp
  FROM provider_coverage c
  JOIN station s ON s.station_id = c.station_id;

-- ------------------------------------------------------------------------------------------------------------
-- v_job_run_pending: finished ingest cycles whose fish hand-over to MSSQL has not run yet.
-- Called by: env_service (hand-over job), then sp_job_run_handed_over.
-- ------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_job_run_pending AS
SELECT j.job_run_id, j.service, j.job, j.started, j.finished, j.status, j.items, j.note
  FROM job_run j
 WHERE j.handed_over IS NULL;

-- ------------------------------------------------------------------------------------------------------------
-- v_station_state: per station, what the MSSQL fish model reads (replaces CurrentWaterState there):
-- the current reading and the flow state. sid = MSSQL WaterStation.sid.
-- Called by: env_service (hand-over: env.sp_push_station_state) and the REST API (/stations/{sid}/current).
-- ------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_station_state AS
SELECT s.station_id AS sid, s.mli, s.country, s.state
     , c.ts, c.discharge, c.turbidity, c.oxygen, c.ph, c.elevation
     , c.flow_state, c.q_ratio_1d, c.q_ratio_2d, c.q_ratio_3_7d, c.q_median_30d, c.days_since_peak, c.flow_stamp
     , c.iter_stamp
  FROM station_current c
  JOIN station s ON s.station_id = c.station_id;

-- ------------------------------------------------------------------------------------------------------------
-- v_station_day: per station and day, 3 days back .. 15 days ahead (UTC), the weather and pressure the MSSQL fish
-- model reads (replaces StationPressureDay + the weather_Forecast slice there). pressure in mm Hg.
-- Called by: env_service (hand-over: env.sp_push_station_day).
-- ------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_station_day AS
SELECT s.station_id AS sid, s.mli, w.dt
     , w.tm_day, w.tm_high, w.tm_low, w.pop, w.weather_code
     , COALESCE(p.pressure_mm, w.pressure_mm) AS pressure_mm
     , p.state AS pressure_state, p.front_dt, p.swing_mm, p.strength, p.season, p.weight AS pressure_weight
     , GREATEST(w.stamp, COALESCE(p.stamp, w.stamp)) AS stamp
  FROM weather_day w
  JOIN station s ON s.station_id = w.station_id
  LEFT JOIN station_pressure_day p ON p.station_id = w.station_id AND p.dt = w.dt
 WHERE w.dt BETWEEN UTC_DATE() - INTERVAL 3 DAY AND UTC_DATE() + INTERVAL 15 DAY;
