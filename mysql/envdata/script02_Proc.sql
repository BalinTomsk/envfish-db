-- envdata/script02_Proc.sql: every write, and every parameterised read, of the water/weather database.
-- Ported 2026-11-24 from envfish-db/mssql (sp_UpdateWaterData, sp_push_us_water_data, TR_insWaterData,
-- TR_CurrentWaterState, TR_ows_meteo + sp_ows_meteo_canonical, sp_water_station_503_*, sp_save_weather_gov_station,
-- sp_save_weather_station_coverage, sp_clean_old_*, sp_fill_flow_state + fn_station_flow_state,
-- sp_fill_pressure_state + fn_station_pressure_days). Each procedure names its caller.
--
-- Rules (see script0.sql): no transaction control inside (a caller or a test wraps them), no parameter defaults
-- (pass NULL), UTC everywhere, pressure in mm Hg. Batches come in as ONE JSON array parameter (MySQL has no
-- table-valued parameters) and are expanded with JSON_TABLE. An unknown station mli is an error (SQLSTATE 45000):
-- the collectors only ever process stations they read from v_station_*_due, so an unknown one is a bug.
--
-- Idempotent: DROP PROCEDURE IF EXISTS + CREATE.

DELIMITER //

-- ============================================================================================================
-- Station mirror
-- ============================================================================================================

-- Upserts stations from the MSSQL master (env.fn_station_list(@since) -> JSON). One element per station:
--   {"sid":123,"mli":"02HB004","id":"<WaterStation.id>","country":"CA","state":"ON","lat":43.1,"lon":-79.2,
--    "tz":-5,"locType":2,"locName":"...","lakeId":"<guid>|null","lakeName":"...","elevation":120,
--    "agency":"...","hasFish":1,"supported":1,"stamp":"2026-11-24 10:00:00"}
-- Identity columns are overwritten; `supported` is taken only when the row is created (afterwards the 503 back-off
-- procedures own it). Stations missing from the JSON are left alone (the feed is incremental).
-- p_count = elements in the JSON.
-- Called by: env_service StationMirrorJob (hourly).
DROP PROCEDURE IF EXISTS sp_station_mirror //
CREATE PROCEDURE sp_station_mirror(IN p_rows JSON, OUT p_count INT)
BEGIN
    DECLARE v_now DATETIME DEFAULT UTC_TIMESTAMP();
    SET p_count = COALESCE(JSON_LENGTH(p_rows), 0);

    INSERT INTO station (station_id, mli, ws_id, country, state, lat, lon, tz, loc_type, loc_name, lake_id, lake_name,
                         elevation, agency, has_fish, master_stamp, mirror_stamp, supported)
    SELECT * FROM (
        SELECT j.sid, j.mli, j.ws_id, j.country, j.state, j.lat, j.lon, j.tz, COALESCE(j.loc_type, 0) AS loc_type,
               COALESCE(j.loc_name, '') AS loc_name, j.lake_id, COALESCE(j.lake_name, '') AS lake_name,
               j.elevation, j.agency, COALESCE(j.has_fish, 0) AS has_fish, COALESCE(j.stamp, v_now) AS master_stamp,
               v_now AS mirror_stamp, COALESCE(j.supported, 1) AS supported
          FROM JSON_TABLE(p_rows, '$[*]' COLUMNS (
                   sid        INT           PATH '$.sid',
                   mli        VARCHAR(64)   PATH '$.mli',
                   ws_id      CHAR(36)      PATH '$.id',
                   country    CHAR(2)       PATH '$.country',
                   state      CHAR(2)       PATH '$.state',
                   lat        DOUBLE        PATH '$.lat',
                   lon        DOUBLE        PATH '$.lon',
                   tz         INT           PATH '$.tz',
                   loc_type   INT           PATH '$.locType',
                   loc_name   VARCHAR(255)  PATH '$.locName',
                   lake_id    CHAR(36)      PATH '$.lakeId',
                   lake_name  VARCHAR(64)   PATH '$.lakeName',
                   elevation  INT           PATH '$.elevation',
                   agency     VARCHAR(128)  PATH '$.agency',
                   has_fish   TINYINT       PATH '$.hasFish',
                   supported  TINYINT       PATH '$.supported',
                   stamp      DATETIME      PATH '$.stamp')) j
         WHERE j.sid IS NOT NULL AND j.mli IS NOT NULL
    ) AS src
    ON DUPLICATE KEY UPDATE
        mli = src.mli, ws_id = src.ws_id, country = src.country, state = src.state, lat = src.lat, lon = src.lon,
        tz = src.tz, loc_type = src.loc_type, loc_name = src.loc_name, lake_id = src.lake_id,
        lake_name = src.lake_name, elevation = src.elevation, agency = src.agency, has_fish = src.has_fish,
        master_stamp = src.master_stamp, mirror_stamp = src.mirror_stamp;
END //

-- ============================================================================================================
-- Water readings
-- ============================================================================================================

-- Recomputes one station's station_current from its readings (the port of TR_insWaterData + TR_CurrentWaterState).
-- Only a reading that CARRIES something counts (an empty reading is no reading, so it never moves ts forward).
-- A PARTIAL reading still counts and keeps what it does not carry: each value is the newest non-NULL one among the
-- readings from the current ts on. Readings older than the current ts change nothing, so a late or replayed batch
-- can never move the state back in time (TR_insWaterData took the batch's last row, whatever its time).
-- station.upd_data follows ts.
-- Called by: sp_water_save_ca, sp_water_save_us (never by an application).
DROP PROCEDURE IF EXISTS sp_station_current_refresh //
CREATE PROCEDURE sp_station_current_refresh(IN p_station_id INT)
BEGIN
    DECLARE v_from DATETIME;
    DECLARE v_ts DATETIME;

    SELECT ts INTO v_from FROM station_current WHERE station_id = p_station_id;
    SET v_from = COALESCE(v_from, '1000-01-01 00:00:00');

    SELECT MAX(r.ts) INTO v_ts
      FROM water_reading r
     WHERE r.station_id = p_station_id AND r.ts >= v_from
       AND (r.discharge IS NOT NULL OR r.turbidity IS NOT NULL OR r.oxygen IS NOT NULL
            OR r.ph IS NOT NULL OR r.elevation IS NOT NULL);

    IF v_ts IS NOT NULL THEN
        INSERT INTO station_current (station_id, ts, discharge, turbidity, oxygen, ph, elevation, iter_stamp)
        SELECT * FROM (
            SELECT p_station_id AS sid, v_ts AS ts
                 , (SELECT r.discharge FROM water_reading r WHERE r.station_id = p_station_id AND r.ts BETWEEN v_from AND v_ts
                       AND r.discharge IS NOT NULL ORDER BY r.ts DESC LIMIT 1) AS discharge
                 , (SELECT r.turbidity FROM water_reading r WHERE r.station_id = p_station_id AND r.ts BETWEEN v_from AND v_ts
                       AND r.turbidity IS NOT NULL ORDER BY r.ts DESC LIMIT 1) AS turbidity
                 , (SELECT r.oxygen FROM water_reading r WHERE r.station_id = p_station_id AND r.ts BETWEEN v_from AND v_ts
                       AND r.oxygen IS NOT NULL ORDER BY r.ts DESC LIMIT 1) AS oxygen
                 , (SELECT r.ph FROM water_reading r WHERE r.station_id = p_station_id AND r.ts BETWEEN v_from AND v_ts
                       AND r.ph IS NOT NULL ORDER BY r.ts DESC LIMIT 1) AS ph
                 , (SELECT r.elevation FROM water_reading r WHERE r.station_id = p_station_id AND r.ts BETWEEN v_from AND v_ts
                       AND r.elevation IS NOT NULL ORDER BY r.ts DESC LIMIT 1) AS elevation
                 , UTC_TIMESTAMP() AS iter_stamp
        ) AS src
        ON DUPLICATE KEY UPDATE
            ts = src.ts,
            discharge = COALESCE(src.discharge, station_current.discharge),
            turbidity = COALESCE(src.turbidity, station_current.turbidity),
            oxygen    = COALESCE(src.oxygen,    station_current.oxygen),
            ph        = COALESCE(src.ph,        station_current.ph),
            elevation = COALESCE(src.elevation, station_current.elevation),
            iter_stamp = src.iter_stamp;

        UPDATE station SET upd_data = v_ts WHERE station_id = p_station_id;
    END IF;
END //

-- Saves one Canadian station's readings (port of sp_UpdateWaterData, one call per batch instead of one EXEC per row).
-- p_rows = [{"s":"2026-11-24 10:05:00","e":1.234,"d":56.7}, ...]  s = UTC time, e = water level m, d = discharge m3/s.
-- An existing reading at the same time is overwritten (as before). -999 ("no reading") is stored as NULL.
-- Up to ~500 rows per call (waterservice's MaxReadingsPerBatch).
-- Called by: waterservice (C#) Data/WaterDataRepository.SaveStationDataAsync (EC / ECCC stations).
DROP PROCEDURE IF EXISTS sp_water_save_ca //
CREATE PROCEDURE sp_water_save_ca(IN p_mli VARCHAR(64), IN p_rows JSON)
BEGIN
    DECLARE v_sid INT;
    SELECT station_id INTO v_sid FROM station WHERE mli = p_mli;
    IF v_sid IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'sp_water_save_ca: unknown station mli';
    END IF;

    INSERT INTO water_reading (station_id, ts, elevation, discharge)
    SELECT * FROM (
        SELECT v_sid AS sid, j.s AS ts, j.e AS elevation,
               CASE WHEN TRUNCATE(j.d, 0) = -999 THEN NULL ELSE j.d END AS discharge
          FROM JSON_TABLE(p_rows, '$[*]' COLUMNS (
                   s DATETIME PATH '$.s',
                   e DOUBLE   PATH '$.e',
                   d DOUBLE   PATH '$.d')) j
         WHERE j.s IS NOT NULL
    ) AS src
    ON DUPLICATE KEY UPDATE elevation = src.elevation, discharge = src.discharge;

    CALL sp_station_current_refresh(v_sid);
END //

-- Saves one US station's USGS series (port of sp_push_us_water_data, all series of a station in ONE call).
-- p_series = [{"name":"Streamflow","unit":"ft^3/s","points":[{"d":"2026-11-23","v":12.3}, ...]}, ...]
-- name/unit are UsgsParameterMap's legacy (WaterML) pairs; d is a UTC date (one reading per day, stored at 00:00).
-- Every value is stored METRIC, as before: level m, discharge m3/s, velocity m/s, wind km/h, precipitation mm -
-- except pressure, now mm Hg (WaterData held hPa) - and pH as the real value (WaterData truncated it to an
-- integer). Dissolved oxygen is taken only in mg/L (the "% saturation" series used to overwrite it).
-- All series of a day are merged into ONE row before it is written, and a day that carries no mapped value is not
-- written at all (WaterData got an empty row per unmapped series, and only the first series of a new day reached
-- CurrentWaterState, because its trigger fired on INSERT only). Existing values are kept where a series is absent.
-- Not stored (as before): water/air temperature, cyanobacteria, orthophosphate, and any unmapped series.
-- Called by: waterservice (C#) Data/WaterDataRepository.SaveUsStationDataAsync (USGS stations).
DROP PROCEDURE IF EXISTS sp_water_save_us //
CREATE PROCEDURE sp_water_save_us(IN p_mli VARCHAR(64), IN p_state CHAR(2), IN p_series JSON)
BEGIN
    DECLARE v_sid INT;
    SELECT station_id INTO v_sid FROM station WHERE mli = p_mli;
    IF v_sid IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'sp_water_save_us: unknown station mli';
    END IF;

    INSERT INTO water_reading (station_id, ts, discharge, elevation, velocity, turbidity, pressure_mm, wind, winddir,
                               humidity, precipitation, chlorophylls, phycocyanins, phycoerythrin, nitrate, chloride,
                               oxygen, ph, salinity)
    SELECT * FROM (
        WITH pts AS
        (
            SELECT j.name, TRIM(COALESCE(j.unit, '')) AS u, j.d, j.v
              FROM JSON_TABLE(p_series, '$[*]' COLUMNS (
                       name VARCHAR(255) PATH '$.name',
                       unit VARCHAR(255) PATH '$.unit',
                       NESTED PATH '$.points[*]' COLUMNS (
                           d DATE   PATH '$.d',
                           v DOUBLE PATH '$.v'))) j
             WHERE j.d IS NOT NULL AND j.v IS NOT NULL
        ),
        conv AS
        (
            SELECT d
                 , CASE WHEN name = 'Streamflow' THEN v *
                        CASE WHEN u IN ('ft^3/s', 'tidally filtered, ft^3/s') THEN 0.028316846592
                             WHEN u = 'gal/min' THEN 0.0000630901964 ELSE 1 END END AS discharge
                 , CASE WHEN name IN ('Gage height', 'Stream water level elevation above NAVD 1988',
                                      'Elevation of reservoir water surface above datum',
                                      'Lake or reservoir elevation above United States Bureau of Reclamation Klamath Basin (USBRKB) Datum',
                                      'Lake or reservoir water surface elevation above NAVD 1988',
                                      'Lake or reservoir water surface elevation above NGVD 1929',
                                      'Estuary or ocean water surface elevation above NAVD 1988',
                                      'Stream water level elevation above NGVD 1929',
                                      'Estuary or ocean water surface elevation above NGVD 1929',
                                      'Lake or reservoir elevation above New York State Barge Canal Datum (NYBCD)')
                        THEN v * CASE WHEN u IN ('ft', 'in ft', 'feet') THEN 0.3048 ELSE 1 END END AS elevation
                 , CASE WHEN name IN ('Water velocity reading from field sensor', 'Mean water velocity for discharge computation')
                        THEN v * CASE WHEN u IN ('ft/s', 'feet per second') THEN 0.3048
                                      WHEN u IN ('miles per hour', 'mph') THEN 0.44704
                                      WHEN u = 'knots' THEN 0.514444 ELSE 1 END END AS velocity
                 , CASE WHEN name = 'Turbidity' THEN v END AS turbidity
                 , CASE WHEN name = 'Barometric pressure'
                        THEN v * CASE WHEN u = 'mmHg' THEN 1
                                      WHEN u = 'uncorrected, kPa' THEN 7.50062 ELSE 0.750062 END END AS pressure_mm
                 , CASE WHEN name IN ('Wind speed', 'Wind gust speed')
                        THEN v * CASE WHEN u IN ('mph', 'air, mph') THEN 1.609344
                                      WHEN u IN ('m/s', 'air, meters per second') THEN 3.6
                                      WHEN u IN ('knots', 'air, kn') THEN 1.852 ELSE 1 END END AS wind
                 , CASE WHEN name IN ('Wind direction', 'Wind gust direction') THEN v END AS winddir
                 , CASE WHEN name = 'Relative humidity' THEN v END AS humidity
                 , CASE WHEN name = 'Precipitation'
                        THEN v * CASE WHEN u IN ('total, in', 'cumulative, inches') THEN 25.4 ELSE 1 END END AS precipitation
                 , CASE WHEN name IN ('Chlorophylls', 'Chlorophyll <i>a</i>') THEN v END AS chlorophylls
                 , CASE WHEN name = 'Phycocyanins (cyanobacteria)' THEN v END AS phycocyanins
                 , CASE WHEN name = 'Phycoerythrin (blue-green algae)' THEN v END AS phycoerythrin
                 , CASE WHEN name = 'Nitrate' THEN v END AS nitrate
                 , CASE WHEN name = 'Chloride' THEN v END AS chloride
                 , CASE WHEN name = 'Dissolved oxygen' AND u LIKE '%mg/L%' THEN v END AS oxygen
                 , CASE WHEN name = 'pH' THEN v END AS ph
                 , CASE WHEN name = 'Salinity' THEN v END AS salinity
              FROM pts
        ),
        day_row AS
        (
            SELECT d
                 , MAX(discharge) AS discharge, MAX(elevation) AS elevation, MAX(velocity) AS velocity
                 , MAX(turbidity) AS turbidity, ROUND(MAX(pressure_mm), 1) AS pressure_mm, MAX(wind) AS wind
                 , ROUND(MAX(winddir)) AS winddir, MAX(humidity) AS humidity, MAX(precipitation) AS precipitation
                 , MAX(chlorophylls) AS chlorophylls, MAX(phycocyanins) AS phycocyanins
                 , MAX(phycoerythrin) AS phycoerythrin, MAX(nitrate) AS nitrate, MAX(chloride) AS chloride
                 , MAX(oxygen) AS oxygen, ROUND(MAX(ph), 2) AS ph, MAX(salinity) AS salinity
              FROM conv
             GROUP BY d
        )
        SELECT v_sid AS sid, CAST(d AS DATETIME) AS ts, discharge, elevation, velocity, turbidity, pressure_mm, wind,
               winddir, humidity, precipitation, chlorophylls, phycocyanins, phycoerythrin, nitrate, chloride,
               oxygen, ph, salinity
          FROM day_row
         WHERE COALESCE(discharge, elevation, velocity, turbidity, pressure_mm, wind, winddir, humidity, precipitation,
                        chlorophylls, phycocyanins, phycoerythrin, nitrate, chloride, oxygen, ph, salinity) IS NOT NULL
    ) AS src
    ON DUPLICATE KEY UPDATE
        discharge     = COALESCE(src.discharge,     water_reading.discharge),
        elevation     = COALESCE(src.elevation,     water_reading.elevation),
        velocity      = COALESCE(src.velocity,      water_reading.velocity),
        turbidity     = COALESCE(src.turbidity,     water_reading.turbidity),
        pressure_mm   = COALESCE(src.pressure_mm,   water_reading.pressure_mm),
        wind          = COALESCE(src.wind,          water_reading.wind),
        winddir       = COALESCE(src.winddir,       water_reading.winddir),
        humidity      = COALESCE(src.humidity,      water_reading.humidity),
        precipitation = COALESCE(src.precipitation, water_reading.precipitation),
        chlorophylls  = COALESCE(src.chlorophylls,  water_reading.chlorophylls),
        phycocyanins  = COALESCE(src.phycocyanins,  water_reading.phycocyanins),
        phycoerythrin = COALESCE(src.phycoerythrin, water_reading.phycoerythrin),
        nitrate       = COALESCE(src.nitrate,       water_reading.nitrate),
        chloride      = COALESCE(src.chloride,      water_reading.chloride),
        oxygen        = COALESCE(src.oxygen,        water_reading.oxygen),
        ph            = COALESCE(src.ph,            water_reading.ph),
        salinity      = COALESCE(src.salinity,      water_reading.salinity);

    IF p_state IS NOT NULL AND p_state <> '' THEN
        UPDATE station SET state = p_state WHERE station_id = v_sid AND (state IS NULL OR state <> p_state);
    END IF;

    CALL sp_station_current_refresh(v_sid);
END //

-- One-off load of MSSQL WaterData (env_service plan step 3). p_rows = rows ALREADY converted to envdata's units by
-- EnvService.Migrator (metric, pressure in mm Hg, -999 as null, pH null: WaterData's US pH is truncated):
--   [{"sid":123,"ts":"yyyy-MM-dd HH:mm:ss","discharge":..,"elevation":..,"turbidity":..,"oxygen":..,"ph":..,
--     "velocity":..,"pressure_mm":..,"precipitation":..,"wind":..,"winddir":..,"humidity":..,"phycocyanins":..,
--     "chlorophylls":..,"nitrate":..,"chloride":..,"phycoerythrin":..,"salinity":..}, ...]  (absent = null)
-- Several stations per call. A value already in envdata WINS (live 11.0.0 data is newer than anything copied); a
-- missing one is filled. Rows of an unknown station, and rows carrying no value, are skipped. station_current is
-- refreshed for every station of the batch. p_count = rows stored or merged.
-- Called by: EnvService.Migrator (one-off; never by a service).
DROP PROCEDURE IF EXISTS sp_water_backfill //
CREATE PROCEDURE sp_water_backfill(IN p_rows JSON, OUT p_count INT)
BEGIN
    DECLARE v_sid INT;
    DECLARE v_done INT DEFAULT 0;
    DECLARE c_sid CURSOR FOR SELECT DISTINCT station_id FROM tmp_backfill;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    DROP TEMPORARY TABLE IF EXISTS tmp_backfill;
    CREATE TEMPORARY TABLE tmp_backfill
    (
        station_id INT NOT NULL, ts DATETIME NOT NULL, discharge DOUBLE, elevation DOUBLE, turbidity DOUBLE,
        oxygen DOUBLE, ph DECIMAL(4,2), velocity DOUBLE, pressure_mm DECIMAL(5,1), precipitation DOUBLE, wind DOUBLE,
        winddir SMALLINT, humidity DOUBLE, phycocyanins DOUBLE, chlorophylls DOUBLE, nitrate DOUBLE, chloride DOUBLE,
        phycoerythrin DOUBLE, salinity DOUBLE,
        PRIMARY KEY (station_id, ts)
    );

    INSERT IGNORE INTO tmp_backfill
    SELECT j.sid, j.ts, j.discharge, j.elevation, j.turbidity, j.oxygen, j.ph, j.velocity, j.pressure_mm,
           j.precipitation, j.wind, j.winddir, j.humidity, j.phycocyanins, j.chlorophylls, j.nitrate, j.chloride,
           j.phycoerythrin, j.salinity
      FROM JSON_TABLE(p_rows, '$[*]' COLUMNS (
               sid           INT           PATH '$.sid',
               ts            DATETIME      PATH '$.ts',
               discharge     DOUBLE        PATH '$.discharge',
               elevation     DOUBLE        PATH '$.elevation',
               turbidity     DOUBLE        PATH '$.turbidity',
               oxygen        DOUBLE        PATH '$.oxygen',
               ph            DECIMAL(4,2)  PATH '$.ph',
               velocity      DOUBLE        PATH '$.velocity',
               pressure_mm   DECIMAL(5,1)  PATH '$.pressure_mm',
               precipitation DOUBLE        PATH '$.precipitation',
               wind          DOUBLE        PATH '$.wind',
               winddir       SMALLINT      PATH '$.winddir',
               humidity      DOUBLE        PATH '$.humidity',
               phycocyanins  DOUBLE        PATH '$.phycocyanins',
               chlorophylls  DOUBLE        PATH '$.chlorophylls',
               nitrate       DOUBLE        PATH '$.nitrate',
               chloride      DOUBLE        PATH '$.chloride',
               phycoerythrin DOUBLE        PATH '$.phycoerythrin',
               salinity      DOUBLE        PATH '$.salinity')) j
      JOIN station s ON s.station_id = j.sid
     WHERE j.ts IS NOT NULL
       AND COALESCE(j.discharge, j.elevation, j.turbidity, j.oxygen, j.ph, j.velocity, j.pressure_mm, j.precipitation,
                    j.wind, j.winddir, j.humidity, j.phycocyanins, j.chlorophylls, j.nitrate, j.chloride,
                    j.phycoerythrin, j.salinity) IS NOT NULL;

    SET p_count = (SELECT COUNT(*) FROM tmp_backfill);

    INSERT INTO water_reading (station_id, ts, discharge, elevation, turbidity, oxygen, ph, velocity, pressure_mm,
                               precipitation, wind, winddir, humidity, phycocyanins, chlorophylls, nitrate, chloride,
                               phycoerythrin, salinity)
    SELECT * FROM (SELECT * FROM tmp_backfill) AS src
    ON DUPLICATE KEY UPDATE
        discharge     = COALESCE(water_reading.discharge,     src.discharge),
        elevation     = COALESCE(water_reading.elevation,     src.elevation),
        turbidity     = COALESCE(water_reading.turbidity,     src.turbidity),
        oxygen        = COALESCE(water_reading.oxygen,        src.oxygen),
        ph            = COALESCE(water_reading.ph,            src.ph),
        velocity      = COALESCE(water_reading.velocity,      src.velocity),
        pressure_mm   = COALESCE(water_reading.pressure_mm,   src.pressure_mm),
        precipitation = COALESCE(water_reading.precipitation, src.precipitation),
        wind          = COALESCE(water_reading.wind,          src.wind),
        winddir       = COALESCE(water_reading.winddir,       src.winddir),
        humidity      = COALESCE(water_reading.humidity,      src.humidity),
        phycocyanins  = COALESCE(water_reading.phycocyanins,  src.phycocyanins),
        chlorophylls  = COALESCE(water_reading.chlorophylls,  src.chlorophylls),
        nitrate       = COALESCE(water_reading.nitrate,       src.nitrate),
        chloride      = COALESCE(water_reading.chloride,      src.chloride),
        phycoerythrin = COALESCE(water_reading.phycoerythrin, src.phycoerythrin),
        salinity      = COALESCE(water_reading.salinity,      src.salinity);

    OPEN c_sid;
    refresh: LOOP
        FETCH c_sid INTO v_sid;
        IF v_done = 1 THEN
            LEAVE refresh;
        END IF;
        CALL sp_station_current_refresh(v_sid);
    END LOOP;
    CLOSE c_sid;

    DROP TEMPORARY TABLE IF EXISTS tmp_backfill;
END //

-- ============================================================================================================
-- HTTP 503 back-off of the water collectors (ports of sp_water_station_503_*; same rules)
-- ============================================================================================================

-- Re-enables every station whose weekly/monthly retry date has arrived.
-- Called by: waterservice (C#) Data/StationHttp503BackoffRepository.RefreshDueAsync, before loading stations.
DROP PROCEDURE IF EXISTS sp_station_503_refresh_due //
CREATE PROCEDURE sp_station_503_refresh_due(IN p_today DATE)
BEGIN
    UPDATE station
       SET backoff_state = 0, backoff_next_date = NULL, supported = 1
     WHERE backoff_state IN (2, 3) AND backoff_next_date IS NOT NULL AND backoff_next_date <= p_today;
END //

-- Advances a station's HTTP 503 back-off:
--   states 0/1 track daily and stay supported; 3 consecutive daily 503 dates -> state 2 (weekly), unsupported;
--   4 weekly 503 dates -> state 3 (monthly), unsupported; a repeated 503 on the same date changes nothing.
-- Called by: waterservice (C#) Data/StationHttp503BackoffRepository.RecordHttp503Async.
DROP PROCEDURE IF EXISTS sp_station_503_record //
CREATE PROCEDURE sp_station_503_record(IN p_provider VARCHAR(64), IN p_country CHAR(2), IN p_mli VARCHAR(64),
                                       IN p_state CHAR(2), IN p_today DATE)
proc: BEGIN
    DECLARE v_state INT;
    DECLARE v_daily INT;
    DECLARE v_weekly INT;
    DECLARE v_last DATE;
    DECLARE v_next DATE;

    SELECT backoff_state, backoff_daily_503_count, backoff_weekly_503_count, backoff_last_503_date
      INTO v_state, v_daily, v_weekly, v_last
      FROM station
     WHERE country = p_country AND mli = p_mli
       FOR UPDATE;

    IF v_state IS NULL THEN
        LEAVE proc;
    END IF;

    IF v_state IN (0, 1) THEN
        SET v_daily = CASE WHEN v_last IS NULL THEN 1
                           WHEN v_last = p_today THEN v_daily
                           WHEN v_last = p_today - INTERVAL 1 DAY THEN v_daily + 1
                           ELSE 1 END;
        SET v_weekly = 0;
        IF v_daily >= 3 THEN
            SET v_state = 2;
            SET v_next = p_today + INTERVAL 7 DAY;
        ELSE
            SET v_state = 1;
            SET v_next = NULL;
        END IF;
    ELSEIF v_state = 2 THEN
        SET v_weekly = CASE WHEN v_last = p_today THEN v_weekly ELSE v_weekly + 1 END;
        IF v_weekly >= 4 THEN
            SET v_state = 3;
            SET v_next = p_today + INTERVAL 1 MONTH;
        ELSE
            SET v_next = p_today + INTERVAL 7 DAY;
        END IF;
    ELSE
        SET v_state = 3;
        SET v_next = p_today + INTERVAL 1 MONTH;
    END IF;

    UPDATE station
       SET state = p_state, backoff_state = v_state, backoff_daily_503_count = v_daily,
           backoff_weekly_503_count = v_weekly, backoff_last_503_date = p_today, backoff_next_date = v_next,
           supported = CASE WHEN v_state IN (2, 3) THEN 0 ELSE supported END
     WHERE country = p_country AND mli = p_mli;
END //

-- A successful run clears the back-off and restores support; stamps station.processed.
-- Called by: waterservice (C#) Data/StationHttp503BackoffRepository.RecordProcessedAsync.
DROP PROCEDURE IF EXISTS sp_station_503_reset //
CREATE PROCEDURE sp_station_503_reset(IN p_provider VARCHAR(64), IN p_country CHAR(2), IN p_mli VARCHAR(64))
BEGIN
    UPDATE station
       SET backoff_state = 0, backoff_daily_503_count = 0, backoff_weekly_503_count = 0,
           backoff_last_503_date = NULL, backoff_next_date = NULL, supported = 1, processed = UTC_TIMESTAMP()
     WHERE country = p_country AND mli = p_mli;
END //

-- Back-off stations by state and stage. Called by: operations / env_service admin (/admin/providers).
DROP PROCEDURE IF EXISTS sp_station_503_summary_by_state //
CREATE PROCEDURE sp_station_503_summary_by_state()
BEGIN
    SELECT state, backoff_stage, station_count FROM v_station_503_summary ORDER BY state, backoff_stage;
END //

-- ============================================================================================================
-- Weather
-- ============================================================================================================

-- A random sample of the stations due for weather (v_station_weather_due), as the MSSQL view's ORDER BY NEWID()
-- gave the C# "SELECT TOP (@limit)". Called by: weather (C#) Data/WeatherStationRepository.FindSupportedStationsAsync.
DROP PROCEDURE IF EXISTS sp_station_weather_due //
CREATE PROCEDURE sp_station_weather_due(IN p_country CHAR(2), IN p_limit INT)
BEGIN
    SELECT mli, lat, lon, state
      FROM v_station_weather_due
     WHERE country = p_country
     ORDER BY flag DESC, RAND()
     LIMIT p_limit;
END //

-- Stores a station's weather payload and shreds it into weather_day (replaces the weather service's direct
-- UPDATE dbo.ows_meteo + trigger TR_ows_meteo + sp_ows_meteo_canonical).
--   1. weather_raw keeps the payload as sent (always, even when it cannot be parsed); station.weather_stamp = now.
--   2. Only the canonical envelope {"schema":"fishfind.weather.forecast/v1", "days":[...]} is shredded; any other
--      document (legacy raw provider JSON, an unknown envelope version) is stored and NOT parsed - a worker deployed
--      ahead of the database must never have its payload half-parsed.
--   3. One weather_day row per $.days[*].date, upserted with the MSSQL rules: tm_high / tm_low / pressure keep the
--      stored value when the payload has none, precipitation day/night default 0, everything else is replaced.
--      pressureHpa is converted to mm Hg here, once: ROUND(hPa x 0.750062, 1).
--   A shred failure never loses the payload: step 2-3 runs in its own handler, the raw row stays.
-- p_days = days shredded; -1 = stored but not shredded.
-- Called by: weather (C#) Data/WeatherDataRepository.SaveAsync.
DROP PROCEDURE IF EXISTS sp_weather_save //
CREATE PROCEDURE sp_weather_save(IN p_mli VARCHAR(64), IN p_type TINYINT, IN p_json MEDIUMTEXT, OUT p_days INT)
BEGIN
    DECLARE v_sid INT;
    DECLARE v_now DATETIME DEFAULT UTC_TIMESTAMP();

    SELECT station_id INTO v_sid FROM station WHERE mli = p_mli;
    IF v_sid IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'sp_weather_save: unknown station mli';
    END IF;

    INSERT INTO weather_raw (station_id, provider_type, payload, stamp)
    VALUES (v_sid, COALESCE(p_type, 0), p_json, v_now) AS new
    ON DUPLICATE KEY UPDATE provider_type = new.provider_type, payload = new.payload, stamp = new.stamp;

    UPDATE station SET weather_stamp = v_now WHERE station_id = v_sid;

    SET p_days = -1;
    shred: BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION SET p_days = -1;

        IF p_json IS NULL OR NOT JSON_VALID(p_json)
           OR COALESCE(JSON_UNQUOTE(JSON_EXTRACT(p_json, '$.schema')), '') <> 'fishfind.weather.forecast/v1' THEN
            LEAVE shred;
        END IF;

        INSERT INTO weather_day (station_id, dt, tm, tm_high, tm_low, tm_day, air_temperature, gpf_day, gpf_night,
                                 humidity, wind_max_speed, wind_degree, wind_direction, pressure_mm, pop, rain_today,
                                 weather_code, icon, short_text, long_text, provider_type, stamp)
        SELECT * FROM (
            SELECT v_sid AS sid, d.dt, d.tm, d.tm_high, d.tm_low, d.tm_day, d.air_temperature,
                   COALESCE(d.gpf_day, 0) AS gpf_day, COALESCE(d.gpf_night, 0) AS gpf_night, d.humidity,
                   d.wind_max_speed, d.wind_degree, d.wind_direction,
                   ROUND(d.pressure_hpa * 0.750062, 1) AS pressure_mm, d.pop, d.rain_today, d.weather_code,
                   d.icon, d.short_text, d.long_text, COALESCE(p_type, 0) AS provider_type, v_now AS stamp
              FROM JSON_TABLE(CAST(p_json AS JSON), '$.days[*]' COLUMNS (
                       dt              DATE          PATH '$.date',
                       tm              TIME          PATH '$.time',
                       tm_high         DOUBLE        PATH '$.tempHighC',
                       tm_low          DOUBLE        PATH '$.tempLowC',
                       air_temperature INT           PATH '$.tempC',
                       tm_day          DOUBLE        PATH '$.tempDayC',
                       humidity        DOUBLE        PATH '$.humidityPct',
                       wind_max_speed  DOUBLE        PATH '$.windSpeedKmh',
                       wind_degree     DOUBLE        PATH '$.windDegrees',
                       wind_direction  VARCHAR(8)    PATH '$.windDirection',
                       pressure_hpa    DOUBLE        PATH '$.pressureHpa',
                       pop             INT           PATH '$.precipChancePct',
                       rain_today      INT           PATH '$.precipMm',
                       gpf_day         DOUBLE        PATH '$.precipDayMm',
                       gpf_night       DOUBLE        PATH '$.precipNightMm',
                       weather_code    INT           PATH '$.weatherCode',
                       icon            VARCHAR(255)  PATH '$.icon',
                       short_text      VARCHAR(64)   PATH '$.conditionsShort',
                       long_text       VARCHAR(255)  PATH '$.conditionsLong')) d
             WHERE d.dt IS NOT NULL
        ) AS src
        ON DUPLICATE KEY UPDATE
            tm_high = COALESCE(src.tm_high, weather_day.tm_high),
            tm_low  = COALESCE(src.tm_low,  weather_day.tm_low),
            gpf_day = src.gpf_day, gpf_night = src.gpf_night,
            humidity = src.humidity, wind_max_speed = src.wind_max_speed, wind_degree = src.wind_degree,
            wind_direction = src.wind_direction, short_text = src.short_text, long_text = src.long_text,
            icon = src.icon, pop = src.pop, tm = src.tm,
            pressure_mm = COALESCE(src.pressure_mm, weather_day.pressure_mm),
            rain_today = src.rain_today, air_temperature = src.air_temperature, tm_day = src.tm_day,
            weather_code = src.weather_code, provider_type = src.provider_type, stamp = src.stamp;

        SET p_days = (SELECT COUNT(*) FROM JSON_TABLE(CAST(p_json AS JSON), '$.days[*]'
                                                   COLUMNS (dt DATE PATH '$.date')) d WHERE d.dt IS NOT NULL);
    END shred;
END //

-- Stores the NWS station resolved for a gauge (port of sp_save_weather_gov_station). p_station_id NULL = "asked,
-- nothing nearby". Called by: weather (C#) Data/WeatherGovStationRepository.SaveAsync.
DROP PROCEDURE IF EXISTS sp_weather_gov_station_save //
CREATE PROCEDURE sp_weather_gov_station_save(IN p_mli VARCHAR(64), IN p_lat DOUBLE, IN p_lon DOUBLE,
                                             IN p_station_id VARCHAR(16))
BEGIN
    DECLARE v_sid INT;
    SELECT station_id INTO v_sid FROM station WHERE mli = p_mli;
    IF v_sid IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'sp_weather_gov_station_save: unknown station mli';
    END IF;

    INSERT INTO weather_gov_station (station_id, nws_station_id, lat, lon, stamp)
    VALUES (v_sid, p_station_id, p_lat, p_lon, UTC_TIMESTAMP()) AS new
    ON DUPLICATE KEY UPDATE nws_station_id = new.nws_station_id, lat = new.lat, lon = new.lon, stamp = new.stamp;
END //

-- Records whether a provider could serve a gauge (port of sp_save_weather_station_coverage).
-- Called by: weather (C#) Data/WeatherStationCoverageRepository.SaveAsync.
DROP PROCEDURE IF EXISTS sp_provider_coverage_save //
CREATE PROCEDURE sp_provider_coverage_save(IN p_mli VARCHAR(64), IN p_provider VARCHAR(32), IN p_covered TINYINT)
BEGIN
    DECLARE v_sid INT;
    SELECT station_id INTO v_sid FROM station WHERE mli = p_mli;
    IF v_sid IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'sp_provider_coverage_save: unknown station mli';
    END IF;

    INSERT INTO provider_coverage (station_id, provider, covered, stamp)
    VALUES (v_sid, p_provider, CASE WHEN p_covered = 0 THEN 0 ELSE 1 END, UTC_TIMESTAMP()) AS new
    ON DUPLICATE KEY UPDATE covered = new.covered, stamp = new.stamp;
END //

-- ============================================================================================================
-- Derived state: daily aggregates, flow, pressure
-- ============================================================================================================

-- (Re)computes water_reading_day for the UTC days p_from .. p_to (one station when p_mli is given).
-- Reads at READ COMMITTED (the caller's isolation is restored on exit): under the default REPEATABLE READ an
-- INSERT ... SELECT takes shared locks on every row it reads, which would block the collectors' writes for the
-- whole run.
-- p_count = day rows written. Called by: sp_fill_flow_state (last 3 days), env_service backfill.
DROP PROCEDURE IF EXISTS sp_fill_water_reading_day //
CREATE PROCEDURE sp_fill_water_reading_day(IN p_from DATE, IN p_to DATE, IN p_mli VARCHAR(64), OUT p_count INT)
BEGIN
    DECLARE v_sid INT;
    DECLARE v_iso VARCHAR(32) DEFAULT @@SESSION.transaction_isolation;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET SESSION transaction_isolation = v_iso;
        RESIGNAL;
    END;
    SET SESSION transaction_isolation = 'READ-COMMITTED';
    IF p_mli IS NOT NULL THEN
        SELECT station_id INTO v_sid FROM station WHERE mli = p_mli;
    END IF;

    INSERT INTO water_reading_day (station_id, dt, n, q_n, q_mean, q_min, q_max, q_last_ts, level_mean, level_min,
                                   level_max, oxygen_mean, oxygen_min, oxygen_max, ph_mean, turbidity_mean, stamp)
    SELECT * FROM (
        SELECT r.station_id AS sid, DATE(r.ts) AS dt, COUNT(*) AS n, COUNT(r.discharge) AS q_n,
               AVG(r.discharge) AS q_mean, MIN(r.discharge) AS q_min, MAX(r.discharge) AS q_max,
               MAX(CASE WHEN r.discharge IS NOT NULL THEN r.ts END) AS q_last_ts,
               AVG(r.elevation) AS level_mean, MIN(r.elevation) AS level_min, MAX(r.elevation) AS level_max,
               AVG(r.oxygen) AS oxygen_mean, MIN(r.oxygen) AS oxygen_min, MAX(r.oxygen) AS oxygen_max,
               ROUND(AVG(r.ph), 2) AS ph_mean, AVG(r.turbidity) AS turbidity_mean, UTC_TIMESTAMP() AS stamp
          FROM water_reading r
         WHERE r.ts >= p_from AND r.ts < p_to + INTERVAL 1 DAY
           AND (p_mli IS NULL OR r.station_id = v_sid)
         GROUP BY r.station_id, DATE(r.ts)
    ) AS src
    ON DUPLICATE KEY UPDATE
        n = src.n, q_n = src.q_n, q_mean = src.q_mean, q_min = src.q_min, q_max = src.q_max, q_last_ts = src.q_last_ts,
        level_mean = src.level_mean, level_min = src.level_min, level_max = src.level_max,
        oxygen_mean = src.oxygen_mean, oxygen_min = src.oxygen_min, oxygen_max = src.oxygen_max,
        ph_mean = src.ph_mean, turbidity_mean = src.turbidity_mean, stamp = src.stamp;

    SET p_count = (SELECT COUNT(*) FROM water_reading_day
                    WHERE dt BETWEEN p_from AND p_to AND (p_mli IS NULL OR station_id = v_sid));
    SET SESSION transaction_isolation = v_iso;
END //

-- Fills the flow columns of station_current (port of sp_fill_flow_state + fn_station_flow_state; same rules).
-- The discharge trend at each gauge as of p_at (NULL = now), from daily mean discharge (water_reading_day, UTC days;
-- the last 3 days are re-aggregated first). Day 0 = the latest day whose last discharge reading is within 2 days of
-- p_at. No state (NULLs, so an old state never lingers) when the data is too thin or suspect: no day 0, fewer than 4
-- of days 0..7, a 30-day median of 0, any negative reading in the 30 days (tidal gauges), day 0 > 20 x day 1, or no
-- day 1 at all (the MSSQL predicate NOT (q0 > 20 x q1) is UNKNOWN then, so it excluded the gauge; kept for parity).
--   q_median_30d   median of the daily means of days 0..29 (PERCENTILE_CONT(0.5): the middle value, or the mean of
--                  the middle two)
--   q_ratio_1d/2d  q0 / day 1's mean, q0 / day 2's mean;   q_ratio_3_7d  q0 / mean of days 3..7 (needs 2 of them)
--   days_since_peak  the day (0..7) of the highest mean, when it is >= 1.5 x the median
--   flow_state     first rule that matches: SPATE, RISING, DROPPING, SETTLED, LOW, FALLING, else STABLE
--                  (thresholds in the CASE below = fn_station_flow_state's; discharge_response_review.md)
-- p_at counts whole days: a day's mean includes all of that day's readings.
--   p_mli            one station only (tests, debugging); skips the age check
--   p_max_age_hours  skip when any flow_stamp is younger than this (NULL = 6, 0 = always run)
-- One run at a time (GET_LOCK, no wait). p_count = stations that got a state; 0 skipped; -1 another run holds the lock.
-- Reads at READ COMMITTED (the caller's isolation is restored on exit): under the default REPEATABLE READ an
-- INSERT ... SELECT takes shared locks on every row it reads, which would block the collectors' writes for the
-- whole run.
-- Called by: env_service hand-over job, after each water cycle.
DROP PROCEDURE IF EXISTS sp_fill_flow_state //
CREATE PROCEDURE sp_fill_flow_state(IN p_at DATETIME, IN p_mli VARCHAR(64), IN p_max_age_hours INT, OUT p_count INT)
proc: BEGIN
    DECLARE v_now DATETIME DEFAULT UTC_TIMESTAMP();
    DECLARE v_at DATETIME DEFAULT COALESCE(p_at, UTC_TIMESTAMP());
    DECLARE v_age INT DEFAULT COALESCE(p_max_age_hours, 6);
    DECLARE v_sid INT;
    DECLARE v_days INT;
    DECLARE v_iso VARCHAR(32);

    IF p_mli IS NULL AND v_age > 0
       AND EXISTS (SELECT 1 FROM station_current WHERE flow_stamp > v_now - INTERVAL v_age HOUR) THEN
        SET p_count = 0;
        LEAVE proc;
    END IF;

    IF p_mli IS NOT NULL THEN
        SELECT station_id INTO v_sid FROM station WHERE mli = p_mli;
    END IF;

    IF COALESCE(GET_LOCK('envdata.sp_fill_flow_state', 0), 0) <> 1 THEN
        SET p_count = -1;
        LEAVE proc;
    END IF;

    SET v_iso = @@SESSION.transaction_isolation;
    SET SESSION transaction_isolation = 'READ-COMMITTED';
    work: BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            SET SESSION transaction_isolation = v_iso;
            DO RELEASE_LOCK('envdata.sp_fill_flow_state');
            RESIGNAL;
        END;

        CALL sp_fill_water_reading_day(DATE(v_at) - INTERVAL 2 DAY, DATE(v_at), p_mli, v_days);

        DROP TEMPORARY TABLE IF EXISTS tmp_flow;
        CREATE TEMPORARY TABLE tmp_flow
        (
            station_id      INT NOT NULL PRIMARY KEY,
            flow_state      VARCHAR(10),
            q_median_30d    DOUBLE,
            q_ratio_1d      DOUBLE,
            q_ratio_2d      DOUBLE,
            q_ratio_3_7d    DOUBLE,
            days_since_peak TINYINT
        );

        INSERT INTO tmp_flow (station_id, flow_state, q_median_30d, q_ratio_1d, q_ratio_2d, q_ratio_3_7d, days_since_peak)
        WITH lastday AS
        (
            SELECT station_id, MAX(dt) AS day0
              FROM water_reading_day
             WHERE q_n > 0 AND dt <= DATE(v_at) AND q_last_ts > v_at - INTERVAL 2 DAY
               AND (p_mli IS NULL OR station_id = v_sid)
             GROUP BY station_id
        ),
        daily AS
        (
            SELECT w.station_id, DATEDIFF(l.day0, w.dt) AS d, w.q_mean AS q, w.q_min AS qmin
              FROM lastday l
              JOIN water_reading_day w ON w.station_id = l.station_id
                                      AND w.dt BETWEEN l.day0 - INTERVAL 29 DAY AND l.day0 AND w.q_n > 0
        ),
        ranked AS
        (
            SELECT station_id, q
                 , ROW_NUMBER() OVER (PARTITION BY station_id ORDER BY q) AS rn
                 , COUNT(*)     OVER (PARTITION BY station_id) AS cnt
              FROM daily
        ),
        med AS
        (
            SELECT station_id, AVG(q) AS m
              FROM ranked
             WHERE rn IN (FLOOR((cnt + 1) / 2), CEIL((cnt + 1) / 2))
             GROUP BY station_id
        ),
        agg AS
        (
            SELECT station_id
                 , MAX(CASE WHEN d = 0 THEN q END) AS q0
                 , MAX(CASE WHEN d = 1 THEN q END) AS q1
                 , MAX(CASE WHEN d = 2 THEN q END) AS q2
                 , AVG(CASE WHEN d BETWEEN 3 AND 7 THEN q END) AS q37
                 , SUM(CASE WHEN d BETWEEN 3 AND 7 THEN 1 ELSE 0 END) AS n37
                 , SUM(CASE WHEN d BETWEEN 0 AND 7 THEN 1 ELSE 0 END) AS n07
                 , MIN(qmin) AS qmin
              FROM daily
             GROUP BY station_id
        ),
        peak AS
        (
            SELECT station_id, d AS pd, q AS pq
                 , ROW_NUMBER() OVER (PARTITION BY station_id ORDER BY q DESC, d) AS prn
              FROM daily
             WHERE d BETWEEN 0 AND 7
        ),
        r AS
        (
            SELECT a.station_id, a.q0, m.m AS med
                 , a.q0 / NULLIF(a.q1, 0) AS r1
                 , a.q0 / NULLIF(a.q2, 0) AS r2
                 , CASE WHEN a.n37 >= 2 THEN a.q0 / NULLIF(a.q37, 0) END AS r37
                 , CASE WHEN p.pq >= 1.5 * m.m THEN p.pd END AS dsp
                 , p.pq, a.q1, a.q2
              FROM agg a
              JOIN med m  ON m.station_id = a.station_id
              JOIN peak p ON p.station_id = a.station_id AND p.prn = 1
             WHERE a.q0 IS NOT NULL AND a.n07 >= 4 AND a.qmin >= 0 AND m.m > 0 AND NOT (a.q0 > 20 * a.q1)
        )
        SELECT r.station_id
             , CASE
                WHEN (r.r1 >= 1.5 AND r.q0 >= 2 * r.med)
                  OR (r.q0 >= 3 * r.med AND (r.dsp = 0 OR COALESCE(r.r1, 1) >= 1))           THEN 'SPATE'
                WHEN r.r1 >= 1.15 OR (r.r37 >= 1.15 AND COALESCE(r.r1, 1) >= 1)             THEN 'RISING'
                WHEN r.dsp BETWEEN 1 AND 7 AND r.q0 < r.pq AND r.q0 >= 1.5 * r.med          THEN 'DROPPING'
                WHEN r.dsp BETWEEN 1 AND 7                                                  THEN 'SETTLED'
                WHEN r.q0 <= 0.5 * r.med AND r.q1 <= 0.5 * r.med AND r.q2 <= 0.5 * r.med    THEN 'LOW'
                WHEN r.r37 <= 0.85                                                          THEN 'FALLING'
                ELSE 'STABLE' END
             , r.med, r.r1, r.r2, r.r37, r.dsp
          FROM r;

        UPDATE station_current c
          LEFT JOIN tmp_flow f ON f.station_id = c.station_id
           SET c.flow_state = f.flow_state, c.q_median_30d = f.q_median_30d,
               c.q_ratio_1d = f.q_ratio_1d, c.q_ratio_2d = f.q_ratio_2d, c.q_ratio_3_7d = f.q_ratio_3_7d,
               c.days_since_peak = f.days_since_peak, c.flow_stamp = v_now
         WHERE p_mli IS NULL OR c.station_id = v_sid;

        SET p_count = (SELECT COUNT(*) FROM tmp_flow);
        DROP TEMPORARY TABLE IF EXISTS tmp_flow;
    END work;

    SET SESSION transaction_isolation = v_iso;
    DO RELEASE_LOCK('envdata.sp_fill_flow_state');
END //

-- Fills station_pressure_day for 3 days back .. p_days_ahead days ahead of p_at's date (port of
-- sp_fill_pressure_state + fn_station_pressure_days; the same rules, restated in mm Hg).
-- The daily pressure is weather_day.pressure_mm. A day T is a FRONT (the pressure low) when its pressure is the
-- lowest of T-3..T+2, lower than the day before, at least 4.5 mm (6 hPa) under the highest of the 3 days before and
-- at least 3.0 mm (4 hPa) under the highest of the 2 days after. Each day is counted from the nearest front within
-- 3 days (the later one on a tie): PRE_3, PRE_2, PRE_1, FRONT, POST_1, POST_2, POST_3. Without a front: FALLING
-- (3.0 mm+ lower than the day before), RISING (3.0 mm+ higher) or STABLE. NULL state when fewer than 5 of the 7 days
-- around the day have pressure. strength = 0.5 for a swing (fall + rise) up to 7.5 mm (10 hPa), 1.0 from 11.25 mm
-- (15 hPa), linear between; 1.0 without a front. season = 0.4 under ice (no day above 0 degC in the 5 days to dt,
-- at least 3 known), 0.6 in summer (June-August; December-February south of the equator), else 1.0;
-- weight = strength x season. Arithmetic is exact DECIMAL, so a 4.5 mm threshold is never missed by a float.
-- The window's rows are replaced (forecast pressure changes between runs); rows older than 15 days are deleted.
--   p_mli            one station only (tests, debugging); skips the age check and the retention delete
--   p_max_age_hours  skip when any row's stamp is younger than this (NULL = 6, 0 = always run)
--   p_days_ahead     NULL = 15
-- One run at a time (GET_LOCK, no wait). p_count = rows written; 0 skipped; -1 another run holds the lock.
-- Reads at READ COMMITTED (the caller's isolation is restored on exit): under the default REPEATABLE READ an
-- INSERT ... SELECT takes shared locks on every row it reads, which would block the collectors' writes for the
-- whole run.
-- Called by: env_service hand-over job, after each weather cycle.
DROP PROCEDURE IF EXISTS sp_fill_pressure_state //
CREATE PROCEDURE sp_fill_pressure_state(IN p_at DATETIME, IN p_mli VARCHAR(64), IN p_max_age_hours INT,
                                        IN p_days_ahead INT, OUT p_count INT)
proc: BEGIN
    DECLARE v_now DATETIME DEFAULT UTC_TIMESTAMP();
    DECLARE v_at DATETIME DEFAULT COALESCE(p_at, UTC_TIMESTAMP());
    DECLARE v_age INT DEFAULT COALESCE(p_max_age_hours, 6);
    DECLARE v_from DATE;
    DECLARE v_to DATE;
    DECLARE v_sid INT;
    DECLARE v_iso VARCHAR(32);

    SET v_from = DATE(v_at) - INTERVAL 3 DAY;
    SET v_to   = DATE(v_at) + INTERVAL COALESCE(p_days_ahead, 15) DAY;

    IF p_mli IS NULL AND v_age > 0
       AND EXISTS (SELECT 1 FROM station_pressure_day WHERE stamp > v_now - INTERVAL v_age HOUR) THEN
        SET p_count = 0;
        LEAVE proc;
    END IF;

    IF p_mli IS NOT NULL THEN
        SELECT station_id INTO v_sid FROM station WHERE mli = p_mli;
    END IF;

    IF COALESCE(GET_LOCK('envdata.sp_fill_pressure_state', 0), 0) <> 1 THEN
        SET p_count = -1;
        LEAVE proc;
    END IF;

    SET v_iso = @@SESSION.transaction_isolation;
    SET SESSION transaction_isolation = 'READ-COMMITTED';
    work: BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            SET SESSION transaction_isolation = v_iso;
            DO RELEASE_LOCK('envdata.sp_fill_pressure_state');
            RESIGNAL;
        END;

        DROP TEMPORARY TABLE IF EXISTS tmp_pressure;
        CREATE TEMPORARY TABLE tmp_pressure
        (
            station_id   INT  NOT NULL,
            dt           DATE NOT NULL,
            pressure_mm  DECIMAL(5,1),
            d1_mm        DECIMAL(4,1),
            state        VARCHAR(8),
            front_dt     DATE,
            swing_mm     DECIMAL(4,1),
            strength     DECIMAL(3,2),
            season       DECIMAL(3,2),
            PRIMARY KEY (station_id, dt)
        );

        INSERT INTO tmp_pressure (station_id, dt, pressure_mm, d1_mm, state, front_dt, swing_mm, strength, season)
        WITH RECURSIVE cal AS
        (
            SELECT v_from - INTERVAL 6 DAY AS dt
            UNION ALL
            SELECT dt + INTERVAL 1 DAY FROM cal WHERE dt < v_to + INTERVAL 6 DAY
        ),
        st AS
        (
            SELECT DISTINCT wd.station_id
              FROM weather_day wd
             WHERE wd.pressure_mm IS NOT NULL
               AND wd.dt BETWEEN v_from - INTERVAL 6 DAY AND v_to + INTERVAL 6 DAY
               AND (p_mli IS NULL OR wd.station_id = v_sid)
        ),
        -- dense: one row per station and calendar day. The pressure is looked up on weather_day's primary key; a join
        -- to a materialised CTE here has no index and took 37 s of a 47 s run (11,700 stations, 2026-11-25).
        d AS
        (
            SELECT st.station_id, cal.dt, wd.pressure_mm AS mm, wd.tm_high
              FROM st
             CROSS JOIN cal
              LEFT JOIN weather_day wd ON wd.station_id = st.station_id AND wd.dt = cal.dt
        ),
        w AS
        (
            SELECT d.station_id, d.dt, d.mm
                 , MIN(d.mm)   OVER (wd ROWS BETWEEN 3 PRECEDING AND 2 FOLLOWING) AS low6
                 , MAX(d.mm)   OVER (wd ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING) AS before_max
                 , MAX(d.mm)   OVER (wd ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING) AS after_max
                 , LAG(d.mm)   OVER wd AS prev1
                 , COUNT(d.mm) OVER (wd ROWS BETWEEN 3 PRECEDING AND 3 FOLLOWING) AS n7
                 -- ice: the highs of the 5 days to dt (the series is dense, so 4 rows back = 4 days back)
                 , COUNT(d.tm_high) OVER (wd ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) AS ice_n
                 , MAX(d.tm_high)   OVER (wd ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) AS ice_hi
              FROM d
            WINDOW wd AS (PARTITION BY d.station_id ORDER BY d.dt)
        ),
        t AS
        (
            SELECT w.*
                 , CASE WHEN w.mm IS NOT NULL AND w.mm <= w.low6 AND (w.prev1 IS NULL OR w.mm < w.prev1)
                             AND w.before_max - w.mm >= 4.5 AND w.after_max - w.mm >= 3.0 THEN 1 ELSE 0 END AS is_front
                 , (w.before_max - w.mm) + (w.after_max - w.mm) AS swing
              FROM w
        ),
        k AS
        (
            SELECT t.*
                 , LEAD(t.is_front, 1) OVER wk AS fp1, LAG(t.is_front, 1) OVER wk AS fm1
                 , LEAD(t.is_front, 2) OVER wk AS fp2, LAG(t.is_front, 2) OVER wk AS fm2
                 , LEAD(t.is_front, 3) OVER wk AS fp3, LAG(t.is_front, 3) OVER wk AS fm3
                 , LEAD(t.swing, 1)    OVER wk AS sp1, LAG(t.swing, 1)    OVER wk AS sm1
                 , LEAD(t.swing, 2)    OVER wk AS sp2, LAG(t.swing, 2)    OVER wk AS sm2
                 , LEAD(t.swing, 3)    OVER wk AS sp3, LAG(t.swing, 3)    OVER wk AS sm3
              FROM t
            -- one named window: MySQL evaluates calls that share it in ONE pass; written inline, each of the 12 calls
            -- was its own pass over the whole series (~3 s each for 145,000 station-days, 2026-11-25)
            WINDOW wk AS (PARTITION BY t.station_id ORDER BY t.dt)
        ),
        o AS
        (
            SELECT k.*
                 , CASE WHEN k.is_front = 1 THEN 0 WHEN k.fp1 = 1 THEN 1 WHEN k.fm1 = 1 THEN -1 WHEN k.fp2 = 1 THEN 2
                        WHEN k.fm2 = 1 THEN -2 WHEN k.fp3 = 1 THEN 3 WHEN k.fm3 = 1 THEN -3 END AS foff
              FROM k
        ),
        r AS
        (
            SELECT o.station_id, o.dt, o.mm, o.prev1, o.n7, o.foff, o.ice_n, o.ice_hi
                 , CASE o.foff WHEN 0 THEN o.swing WHEN 1 THEN o.sp1 WHEN -1 THEN o.sm1 WHEN 2 THEN o.sp2
                               WHEN -2 THEN o.sm2 WHEN 3 THEN o.sp3 WHEN -3 THEN o.sm3 END AS fswing
              FROM o
        )
        SELECT r.station_id, r.dt, r.mm
             , r.mm - r.prev1
             , CASE WHEN r.n7 < 5 THEN NULL
                    WHEN r.foff IS NOT NULL THEN
                         CASE r.foff WHEN 3 THEN 'PRE_3' WHEN 2 THEN 'PRE_2' WHEN 1 THEN 'PRE_1' WHEN 0 THEN 'FRONT'
                                     WHEN -1 THEN 'POST_1' WHEN -2 THEN 'POST_2' ELSE 'POST_3' END
                    WHEN r.mm - r.prev1 <= -3.0 THEN 'FALLING'
                    WHEN r.mm - r.prev1 >=  3.0 THEN 'RISING'
                    ELSE 'STABLE' END
             , CASE WHEN r.n7 >= 5 AND r.foff IS NOT NULL THEN r.dt + INTERVAL r.foff DAY END
             , CASE WHEN r.n7 >= 5 THEN r.fswing END
             , CASE WHEN r.n7 < 5 THEN NULL
                    WHEN r.foff IS NULL OR r.fswing >= 11.25 THEN 1.00
                    WHEN r.fswing <= 7.5 THEN 0.50
                    ELSE ROUND(0.5 + (r.fswing - 7.5) * 0.5 / 3.75, 2) END
             , CASE WHEN r.ice_n >= 3 AND r.ice_hi <= 0               THEN 0.40
                    WHEN s.lat >= 0 AND MONTH(r.dt) IN (6, 7, 8)      THEN 0.60
                    WHEN s.lat <  0 AND MONTH(r.dt) IN (12, 1, 2)     THEN 0.60
                    ELSE 1.00 END
          FROM r
          JOIN station s ON s.station_id = r.station_id
         WHERE r.dt BETWEEN v_from AND v_to;

        INSERT INTO station_pressure_day (station_id, dt, pressure_mm, d1_mm, state, front_dt, swing_mm, strength,
                                          season, weight, stamp)
        SELECT * FROM (
            SELECT t.station_id AS sid, t.dt, t.pressure_mm, t.d1_mm, t.state, t.front_dt, t.swing_mm, t.strength,
                   t.season, CAST(t.strength * t.season AS DECIMAL(3,2)) AS weight, v_now AS stamp
              FROM tmp_pressure t
        ) AS src
        ON DUPLICATE KEY UPDATE
            pressure_mm = src.pressure_mm, d1_mm = src.d1_mm, state = src.state, front_dt = src.front_dt,
            swing_mm = src.swing_mm, strength = src.strength, season = src.season, weight = src.weight,
            stamp = src.stamp;

        -- rows of the window that this run no longer produces (a station lost its pressure)
        DELETE spd FROM station_pressure_day spd
          LEFT JOIN tmp_pressure t ON t.station_id = spd.station_id AND t.dt = spd.dt
         WHERE spd.dt BETWEEN v_from AND v_to AND (p_mli IS NULL OR spd.station_id = v_sid) AND t.station_id IS NULL;

        IF p_mli IS NULL THEN
            DELETE FROM station_pressure_day WHERE dt < DATE(v_at) - INTERVAL 15 DAY;
        END IF;

        SET p_count = (SELECT COUNT(*) FROM tmp_pressure);
        DROP TEMPORARY TABLE IF EXISTS tmp_pressure;
    END work;

    SET SESSION transaction_isolation = v_iso;
    DO RELEASE_LOCK('envdata.sp_fill_pressure_state');
END //

-- ============================================================================================================
-- Retention
-- ============================================================================================================

-- Manages water_reading's day partitions (p_YYYYMMDD, each holding one UTC day; p_max above them):
--   * adds the missing days up to p_today + p_days_ahead, split out of p_max (REORGANIZE: only rows already in
--     p_max move, normally none);
--   * drops every day partition whose day is older than p_today - p_days_to_keep (a whole day at a time, no row
--     deletes). The first day partition also holds anything older than its day, so that goes with it.
-- DDL: commits implicitly, so never call it inside a transaction. Runs with the definer's rights (the writers only
-- have EXECUTE). p_dropped / p_added = partitions dropped / added.
-- Called by: sp_clean_old_water_data.
DROP PROCEDURE IF EXISTS sp_water_reading_rotate //
CREATE PROCEDURE sp_water_reading_rotate(IN p_today DATE, IN p_days_to_keep INT, IN p_days_ahead INT,
                                         OUT p_dropped INT, OUT p_added INT)
BEGIN
    DECLARE v_cut DATE DEFAULT p_today - INTERVAL p_days_to_keep DAY;
    DECLARE v_last DATE;
    DECLARE v_day DATE;
    DECLARE v_end DATE DEFAULT p_today + INTERVAL p_days_ahead DAY;
    DECLARE v_parts TEXT DEFAULT '';
    DECLARE v_drop TEXT;

    SET p_added = 0;
    SET p_dropped = 0;

    SELECT MAX(STR_TO_DATE(SUBSTRING(partition_name, 3), '%Y%m%d')) INTO v_last
      FROM information_schema.partitions
     WHERE table_schema = DATABASE() AND table_name = 'water_reading' AND partition_name LIKE 'p\_2%';

    SET v_day = CASE WHEN v_last IS NULL THEN v_cut ELSE v_last + INTERVAL 1 DAY END;
    WHILE v_day <= v_end DO
        SET v_parts = CONCAT(v_parts, 'PARTITION p_', DATE_FORMAT(v_day, '%Y%m%d'),
                             ' VALUES LESS THAN (', TO_DAYS(v_day + INTERVAL 1 DAY), '), ');
        SET p_added = p_added + 1;
        SET v_day = v_day + INTERVAL 1 DAY;
    END WHILE;

    IF p_added > 0 THEN
        SET @envdata_sql = CONCAT('ALTER TABLE water_reading REORGANIZE PARTITION p_max INTO (', v_parts,
                                  'PARTITION p_max VALUES LESS THAN MAXVALUE)');
        PREPARE stmt FROM @envdata_sql;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;
    END IF;

    SELECT GROUP_CONCAT(partition_name ORDER BY partition_name), COUNT(*) INTO v_drop, p_dropped
      FROM information_schema.partitions
     WHERE table_schema = DATABASE() AND table_name = 'water_reading' AND partition_name LIKE 'p\_2%'
       AND STR_TO_DATE(SUBSTRING(partition_name, 3), '%Y%m%d') < v_cut;

    IF p_dropped > 0 THEN
        SET @envdata_sql = CONCAT('ALTER TABLE water_reading DROP PARTITION ', v_drop);
        PREPARE stmt FROM @envdata_sql;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;
    END IF;
    SET @envdata_sql = NULL;
END //

-- Water retention (port of sp_clean_old_water_data): raw readings p_days_to_keep days (NULL = 30) by partition,
-- the daily aggregates and job_run 30 days. Runs DDL (see sp_water_reading_rotate): never inside a transaction.
-- Called by: waterservice (C#) Data/WaterDataRepository.CleanOldWaterDataAsync (nightly).
DROP PROCEDURE IF EXISTS sp_clean_old_water_data //
CREATE PROCEDURE sp_clean_old_water_data(IN p_days_to_keep INT)
BEGIN
    DECLARE v_keep INT DEFAULT COALESCE(p_days_to_keep, 30);
    DECLARE v_dropped INT;
    DECLARE v_added INT;

    CALL sp_water_reading_rotate(UTC_DATE(), v_keep, 3, v_dropped, v_added);

    REPEAT
        DELETE FROM water_reading_day WHERE dt < UTC_DATE() - INTERVAL 30 DAY LIMIT 10000;
    UNTIL ROW_COUNT() = 0 END REPEAT;

    DELETE FROM job_run WHERE finished < UTC_TIMESTAMP() - INTERVAL 30 DAY;
END //

-- Weather retention (port of sp_clean_old_weather_data): weather_day and station_pressure_day older than
-- p_days_back days (NULL = 15). The forecast ahead is never touched. Called by: weather (C#)
-- Data/WeatherDataRepository.CleanOldWeatherDataAsync (nightly).
DROP PROCEDURE IF EXISTS sp_clean_old_weather_data //
CREATE PROCEDURE sp_clean_old_weather_data(IN p_days_back INT)
BEGIN
    DECLARE v_cut DATE DEFAULT UTC_DATE() - INTERVAL COALESCE(p_days_back, 15) DAY;

    REPEAT
        DELETE FROM weather_day WHERE dt < v_cut LIMIT 10000;
    UNTIL ROW_COUNT() = 0 END REPEAT;

    REPEAT
        DELETE FROM station_pressure_day WHERE dt < v_cut LIMIT 10000;
    UNTIL ROW_COUNT() = 0 END REPEAT;
END //

-- ============================================================================================================
-- Ingest cycles and the fish hand-over
-- ============================================================================================================

-- Records one finished ingest cycle. p_status: ok, partial, failed. p_job_run_id = the new row.
-- Called by: waterservice (C#) and weather (C#) at the end of every cycle (replaces their MSSQL fish calls).
DROP PROCEDURE IF EXISTS sp_job_run_record //
CREATE PROCEDURE sp_job_run_record(IN p_service VARCHAR(32), IN p_job VARCHAR(32), IN p_started DATETIME,
                                   IN p_finished DATETIME, IN p_status VARCHAR(16), IN p_items INT,
                                   IN p_note VARCHAR(255), OUT p_job_run_id BIGINT)
BEGIN
    INSERT INTO job_run (service, job, started, finished, status, items, note)
    VALUES (p_service, p_job, p_started, COALESCE(p_finished, UTC_TIMESTAMP()), p_status, COALESCE(p_items, 0), p_note);
    SET p_job_run_id = LAST_INSERT_ID();
END //

-- Marks every pending cycle up to p_up_to_id as handed over. p_count = rows marked.
-- Called by: env_service hand-over job, after the MSSQL push and probability update succeeded.
DROP PROCEDURE IF EXISTS sp_job_run_handed_over //
CREATE PROCEDURE sp_job_run_handed_over(IN p_up_to_id BIGINT, OUT p_count INT)
BEGIN
    UPDATE job_run SET handed_over = UTC_TIMESTAMP() WHERE handed_over IS NULL AND job_run_id <= p_up_to_id;
    SET p_count = ROW_COUNT();
END //

DELIMITER ;
