-- envdata/script01_createTable.sql: tables of the water/weather database.
-- Ported from envfish-db/mssql (WaterStation ingest columns, WaterData, CurrentWaterState, ows_meteo,
-- weather_Forecast, StationPressureDay, weather_gov_station, weather_station_coverage) 2026-11-24.
-- MSSQL keeps WaterStation as the station MASTER; `station` here is its mirror plus the ingest state.

-- ------------------------------------------------------------------------------------------------------------
-- station: one row per water gauge. station_id = MSSQL WaterStation.sid, mli = WaterStation.MLI.
--   Identity columns (mli .. has_fish, master_stamp) are written ONLY by sp_station_mirror (env_service).
--   Ingest state (supported, backoff_*, processed, upd_data, weather_stamp) is owned here and written by the
--   ingest procedures; the mirror sets `supported` only when it creates the row.
--   has_fish = the station's water body has >= 1 species in MSSQL lake_fish (the weather collection criterion,
--   see v_station_weather_due); MSSQL computes it, the mirror carries it.
-- ------------------------------------------------------------------------------------------------------------
CREATE TABLE station
(
    station_id                INT           NOT NULL,
    mli                       VARCHAR(64)   NOT NULL,
    ws_id                     CHAR(36)      NOT NULL,              -- MSSQL WaterStation.id
    country                   CHAR(2)       NOT NULL,              -- CA, US
    state                     CHAR(2)       NULL,
    lat                       DOUBLE        NOT NULL,
    lon                       DOUBLE        NOT NULL,
    tz                        INT           NULL,
    loc_type                  INT           NOT NULL DEFAULT 0,    -- 1 lake, 2 river, 4 stream ... (WaterStation.locType)
    loc_name                  VARCHAR(255)  NOT NULL,
    lake_id                   CHAR(36)      NULL,
    lake_name                 VARCHAR(64)   NOT NULL DEFAULT '',
    elevation                 INT           NULL,
    agency                    VARCHAR(128)  NULL,
    has_fish                  TINYINT(1)    NOT NULL DEFAULT 0,
    master_stamp              DATETIME      NOT NULL,              -- WaterStation.stamp
    mirror_stamp              DATETIME      NOT NULL,              -- when the mirror last wrote the row
    supported                 TINYINT(1)    NOT NULL DEFAULT 1,    -- 0 = the water collectors skip it
    backoff_state             TINYINT       NOT NULL DEFAULT 0,    -- 0 normal, 1 daily, 2 weekly, 3 monthly HTTP 503 backoff
    backoff_daily_503_count   INT           NOT NULL DEFAULT 0,
    backoff_weekly_503_count  INT           NOT NULL DEFAULT 0,
    backoff_last_503_date     DATE          NULL,
    backoff_next_date         DATE          NULL,
    processed                 DATETIME      NULL,
    upd_data                  DATETIME      NULL,                  -- newest reading that reached station_current
    weather_stamp             DATETIME      NULL,                  -- last weather payload saved
    CONSTRAINT pk_station PRIMARY KEY (station_id),
    CONSTRAINT uk_station_mli UNIQUE (mli),
    INDEX ix_station_country (country, supported)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- ------------------------------------------------------------------------------------------------------------
-- water_reading: raw gauge readings (MSSQL WaterData). PK (station_id, ts): a reading is upserted, never duplicated.
--   Real units, unlike WaterData: ph is the real pH (WaterData stored it x10 for CA and TRUNCATED for US),
--   pressure_mm in mm Hg (WaterData held mm Hg before 2026-11-13 and hPa after), discharge m3/s,
--   elevation (water level) m, velocity m/s, wind km/h, precipitation mm. -999 ("no reading") is stored as NULL.
--   Partitioned by UTC day and kept 30 days: sp_water_reading_rotate drops whole days (no row deletes) and adds the
--   next days ahead of time; p_max catches anything beyond the last day partition. No foreign key: partitioned
--   InnoDB tables cannot have one.
-- ------------------------------------------------------------------------------------------------------------
CREATE TABLE water_reading
(
    station_id     INT           NOT NULL,
    ts             DATETIME      NOT NULL,
    discharge      DOUBLE        NULL,
    elevation      DOUBLE        NULL,
    turbidity      DOUBLE        NULL,
    oxygen         DOUBLE        NULL,
    ph             DECIMAL(4,2)  NULL,
    velocity       DOUBLE        NULL,
    pressure_mm    DECIMAL(5,1)  NULL,
    precipitation  DOUBLE        NULL,
    wind           DOUBLE        NULL,
    winddir        SMALLINT      NULL,
    humidity       DOUBLE        NULL,
    phycocyanins   DOUBLE        NULL,
    chlorophylls   DOUBLE        NULL,
    nitrate        DOUBLE        NULL,
    chloride       DOUBLE        NULL,
    phycoerythrin  DOUBLE        NULL,
    salinity       DOUBLE        NULL,
    CONSTRAINT pk_water_reading PRIMARY KEY (station_id, ts)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci
PARTITION BY RANGE (TO_DAYS(ts))
(
    PARTITION p_max VALUES LESS THAN MAXVALUE
);

-- ------------------------------------------------------------------------------------------------------------
-- station_current: the newest reading per station (MSSQL CurrentWaterState), maintained by the two water save
-- procedures through sp_station_current_refresh (the port of trigger TR_insWaterData). Flow columns are written by
-- sp_fill_flow_state.
-- ------------------------------------------------------------------------------------------------------------
CREATE TABLE station_current
(
    station_id       INT           NOT NULL,
    ts               DATETIME      NOT NULL,       -- the newest reading that carried any value
    discharge        DOUBLE        NULL,
    turbidity        DOUBLE        NULL,
    oxygen           DOUBLE        NULL,
    ph               DECIMAL(4,2)  NULL,
    elevation        DOUBLE        NULL,
    iter_stamp       DATETIME      NOT NULL,       -- when the row was last written
    flow_state       VARCHAR(10)   NULL,           -- SPATE, RISING, DROPPING, SETTLED, STABLE, FALLING, LOW
    q_ratio_1d       DOUBLE        NULL,
    q_ratio_2d       DOUBLE        NULL,
    q_ratio_3_7d     DOUBLE        NULL,
    q_median_30d     DOUBLE        NULL,
    days_since_peak  TINYINT       NULL,
    flow_stamp       DATETIME      NULL,
    CONSTRAINT pk_station_current PRIMARY KEY (station_id),
    CONSTRAINT fk_station_current_station FOREIGN KEY (station_id) REFERENCES station (station_id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- ------------------------------------------------------------------------------------------------------------
-- water_reading_day: daily aggregates of water_reading per station and UTC day (new; filled by
-- sp_fill_water_reading_day). Kept 30 days: the flow state needs the median of 30 daily means.
--   q_* = discharge, level_* = elevation. q_last_ts = the last reading of the day that had a discharge.
-- ------------------------------------------------------------------------------------------------------------
CREATE TABLE water_reading_day
(
    station_id      INT           NOT NULL,
    dt              DATE          NOT NULL,
    n               INT           NOT NULL,         -- readings that day
    q_n             INT           NOT NULL,         -- readings with a discharge
    q_mean          DOUBLE        NULL,
    q_min           DOUBLE        NULL,
    q_max           DOUBLE        NULL,
    q_last_ts       DATETIME      NULL,
    level_mean      DOUBLE        NULL,
    level_min       DOUBLE        NULL,
    level_max       DOUBLE        NULL,
    oxygen_mean     DOUBLE        NULL,
    oxygen_min      DOUBLE        NULL,
    oxygen_max      DOUBLE        NULL,
    ph_mean         DECIMAL(4,2)  NULL,
    turbidity_mean  DOUBLE        NULL,
    stamp           DATETIME      NOT NULL,
    CONSTRAINT pk_water_reading_day PRIMARY KEY (station_id, dt),
    INDEX ix_water_reading_day_dt (dt),
    CONSTRAINT fk_water_reading_day_station FOREIGN KEY (station_id) REFERENCES station (station_id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- ------------------------------------------------------------------------------------------------------------
-- weather_raw: the newest provider payload per station (MSSQL ows_meteo), as the weather service sent it:
-- the canonical envelope fishfind.weather.forecast/v1 with the provider's document in $.raw. One row per
-- station, replaced on every save, so a stored payload can be inspected and replayed. MEDIUMTEXT, not JSON:
-- an invalid document must still be stored (and simply not shredded), never rejected.
-- ------------------------------------------------------------------------------------------------------------
CREATE TABLE weather_raw
(
    station_id     INT          NOT NULL,
    provider_type  TINYINT      NOT NULL,   -- 1 TWC, 2 Open-Meteo, 4 Visual Crossing, 5 weather.gov, 6 EC SWOB, 7 WU, 8 Google
    payload        MEDIUMTEXT   NULL,
    stamp          DATETIME     NOT NULL,
    CONSTRAINT pk_weather_raw PRIMARY KEY (station_id),
    CONSTRAINT fk_weather_raw_station FOREIGN KEY (station_id) REFERENCES station (station_id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- ------------------------------------------------------------------------------------------------------------
-- weather_day: one weather row per station and day, history and forecast (MSSQL weather_Forecast), written by
-- sp_weather_save. Kept 15 days back; the forecast reaches as far as the provider does (up to 15-16 days).
--   pressure_mm: mean sea-level pressure in mm Hg, converted once from the payload's pressureHpa.
--   tm_high / tm_low are NULL when unknown (weather_Forecast stored 0 degC, which read as "frozen").
-- ------------------------------------------------------------------------------------------------------------
CREATE TABLE weather_day
(
    station_id       INT           NOT NULL,
    dt               DATE          NOT NULL,
    tm               TIME          NULL,
    tm_high          DOUBLE        NULL,
    tm_low           DOUBLE        NULL,
    tm_day           DOUBLE        NULL,
    air_temperature  INT           NULL,
    gpf_day          DOUBLE        NOT NULL DEFAULT 0,
    gpf_night        DOUBLE        NOT NULL DEFAULT 0,
    humidity         DOUBLE        NULL,
    wind_max_speed   DOUBLE        NULL,
    wind_degree      DOUBLE        NULL,
    wind_direction   VARCHAR(8)    NULL,
    pressure_mm      DECIMAL(5,1)  NULL,
    pop              INT           NULL,
    rain_today       INT           NULL,
    weather_code     INT           NULL,
    icon             VARCHAR(255)  NULL,
    short_text       VARCHAR(64)   NULL,
    long_text        VARCHAR(255)  NULL,
    provider_type    TINYINT       NOT NULL,
    stamp            DATETIME      NOT NULL,
    CONSTRAINT pk_weather_day PRIMARY KEY (station_id, dt),
    INDEX ix_weather_day_dt (dt),
    CONSTRAINT fk_weather_day_station FOREIGN KEY (station_id) REFERENCES station (station_id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- ------------------------------------------------------------------------------------------------------------
-- station_pressure_day: each station's daily air pressure (mm Hg) and its place in the weather-front cycle
-- (MSSQL StationPressureDay), written by sp_fill_pressure_state for 3 days back .. p_days_ahead ahead.
--   state     PRE_3..POST_3 / FALLING / RISING / STABLE (MSSQL pressure_response); NULL when fewer than 5 of the
--             7 days around dt have pressure
--   front_dt  the front (pressure low) the state counts from; swing_mm = fall into it + rise after it
--   strength  0.5 for a swing up to 7.5 mm .. 1.0 from 11.25 mm; season 1.0, 0.6 in summer, 0.4 under ice
--   weight    strength x season: the forecast uses 1 + (factor - 1) x weight
-- Kept 15 days back.
-- ------------------------------------------------------------------------------------------------------------
CREATE TABLE station_pressure_day
(
    station_id   INT           NOT NULL,
    dt           DATE          NOT NULL,
    pressure_mm  DECIMAL(5,1)  NULL,
    d1_mm        DECIMAL(4,1)  NULL,      -- change from the day before
    state        VARCHAR(8)    NULL,
    front_dt     DATE          NULL,
    swing_mm     DECIMAL(4,1)  NULL,
    strength     DECIMAL(3,2)  NULL,
    season       DECIMAL(3,2)  NULL,
    weight       DECIMAL(3,2)  NULL,
    stamp        DATETIME      NOT NULL,
    CONSTRAINT pk_station_pressure_day PRIMARY KEY (station_id, dt),
    INDEX ix_station_pressure_day_dt (dt),
    CONSTRAINT fk_station_pressure_day_station FOREIGN KEY (station_id) REFERENCES station (station_id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- ------------------------------------------------------------------------------------------------------------
-- weather_gov_station: which NWS station serves a gauge (MSSQL weather_gov_station). nws_station_id NULL is a
-- NEGATIVE cache ("asked, nothing nearby"); no row = never asked.
-- ------------------------------------------------------------------------------------------------------------
CREATE TABLE weather_gov_station
(
    station_id      INT          NOT NULL,
    nws_station_id  VARCHAR(16)  NULL,
    lat             DOUBLE       NOT NULL,     -- the coordinate the answer was obtained for
    lon             DOUBLE       NOT NULL,
    stamp           DATETIME     NOT NULL,
    CONSTRAINT pk_weather_gov_station PRIMARY KEY (station_id),
    CONSTRAINT fk_weather_gov_station_station FOREIGN KEY (station_id) REFERENCES station (station_id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- ------------------------------------------------------------------------------------------------------------
-- provider_coverage: whether a weather provider has data for a gauge (MSSQL weather_station_coverage).
-- A current fact, one row per (station, provider), updated in place. No row = not yet checked.
-- ------------------------------------------------------------------------------------------------------------
CREATE TABLE provider_coverage
(
    station_id  INT          NOT NULL,
    provider    VARCHAR(32)  NOT NULL,     -- 'weather-canada', 'weather-gov', 'open', ...
    covered     TINYINT(1)   NOT NULL,
    stamp       DATETIME     NOT NULL,
    CONSTRAINT pk_provider_coverage PRIMARY KEY (station_id, provider),
    INDEX ix_provider_coverage_gaps (provider, covered),
    CONSTRAINT fk_provider_coverage_station FOREIGN KEY (station_id) REFERENCES station (station_id) ON DELETE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;

-- ------------------------------------------------------------------------------------------------------------
-- job_run: one row per finished ingest cycle (new). waterservice / weather record it; env_service reads the
-- unhanded rows (v_job_run_pending), does the fish hand-over to MSSQL, then marks them (sp_job_run_handed_over).
-- The status page reads it too. Kept 30 days.
-- ------------------------------------------------------------------------------------------------------------
CREATE TABLE job_run
(
    job_run_id   BIGINT        NOT NULL AUTO_INCREMENT,
    service      VARCHAR(32)   NOT NULL,     -- waterservice, weather, env_service
    job          VARCHAR(32)   NOT NULL,     -- e.g. water-ca, water-us, weather-open
    started      DATETIME      NOT NULL,
    finished     DATETIME      NOT NULL,
    status       VARCHAR(16)   NOT NULL,     -- ok, partial, failed
    items        INT           NOT NULL DEFAULT 0,
    note         VARCHAR(255)  NULL,
    handed_over  DATETIME      NULL,
    CONSTRAINT pk_job_run PRIMARY KEY (job_run_id),
    INDEX ix_job_run_pending (handed_over, job_run_id),
    INDEX ix_job_run_finished (finished)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_0900_ai_ci;
