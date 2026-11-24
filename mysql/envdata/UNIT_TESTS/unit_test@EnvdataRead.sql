-- MySQL envdata unit tests: the REST read surface of env_service (v_station_info, v_weather_day).
-- One PROCEDURE per test, own handler, own transaction, ROLLBACK.
SET NAMES utf8mb4;

DELIMITER //

DROP PROCEDURE IF EXISTS t_station //
CREATE PROCEDURE t_station(IN p_sid INT, IN p_mli VARCHAR(64), IN p_lake CHAR(36))
BEGIN
    INSERT INTO station (station_id, mli, ws_id, country, state, lat, lon, tz, loc_type, loc_name, lake_id, lake_name,
                         master_stamp, mirror_stamp, has_fish, backoff_state)
    VALUES (p_sid, p_mli, UUID(), 'CA', 'ON', 45.5, -79.25, -5, 2, 'test gauge', p_lake, 'Test River',
            UTC_TIMESTAMP(), UTC_TIMESTAMP(), 1, 2);
END //

-- ----------------------------------------------------------------
-- TEST 1: v_station_info carries identity + lake link, never the ingest back-off columns
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_01 //
CREATE PROCEDURE test_01()
BEGIN
    DECLARE v_ok INT;
    DECLARE v_backoff INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 1 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'R01', '0d012b12-849c-20c3-8532-2f7a21cfcc58');
    SELECT COUNT(*) INTO v_ok FROM v_station_info
     WHERE sid = 90001 AND mli = 'R01' AND lake_id = '0d012b12-849c-20c3-8532-2f7a21cfcc58' AND lake_name = 'Test River'
       AND country = 'CA' AND state = 'ON' AND lat = 45.5 AND lon = -79.25 AND tz = -5 AND loc_type = 2 AND has_fish = 1;
    SELECT COUNT(*) INTO v_backoff FROM information_schema.columns
     WHERE table_schema = DATABASE() AND table_name = 'v_station_info' AND column_name LIKE 'backoff%';
    SELECT IF(v_ok = 1 AND v_backoff = 0, 'TEST 1 PASS: v_station_info has identity + lake, no back-off',
                                          'TEST 1 FAIL: v_station_info wrong') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 2: v_weather_day reaches past the hand-over window (10 days back) and carries the pressure state
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_02 //
CREATE PROCEDURE test_02()
BEGIN
    DECLARE v_ok INT;
    DECLARE v_window INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 2 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'R02', NULL);
    INSERT INTO weather_day (station_id, dt, tm_high, tm_low, pressure_mm, short_text, provider_type, stamp)
    VALUES (90001, UTC_DATE() - INTERVAL 10 DAY, 4, -2, 755.0, 'Snow', 2, UTC_TIMESTAMP());
    INSERT INTO station_pressure_day (station_id, dt, pressure_mm, state, swing_mm, stamp)
    VALUES (90001, UTC_DATE() - INTERVAL 10 DAY, 755.0, 'FALLING', 5.5, UTC_TIMESTAMP());
    SELECT COUNT(*) INTO v_ok FROM v_weather_day
     WHERE sid = 90001 AND dt = UTC_DATE() - INTERVAL 10 DAY AND tm_high = 4 AND tm_low = -2 AND pressure_mm = 755.0
       AND short_text = 'Snow' AND pressure_state = 'FALLING' AND swing_mm = 5.5;
    SELECT COUNT(*) INTO v_window FROM v_station_day WHERE sid = 90001;
    SELECT IF(v_ok = 1 AND v_window = 0, 'TEST 2 PASS: v_weather_day has old days + pressure state',
                                         'TEST 2 FAIL: v_weather_day wrong') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 3: a weather day without a pressure row still appears (state NULL), with its own pressure
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_03 //
CREATE PROCEDURE test_03()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 3 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'R03', NULL);
    INSERT INTO weather_day (station_id, dt, pressure_mm, provider_type, stamp)
    VALUES (90001, UTC_DATE() + INTERVAL 12 DAY, 761.2, 2, UTC_TIMESTAMP());
    SELECT COUNT(*) INTO v_ok FROM v_weather_day
     WHERE sid = 90001 AND pressure_mm = 761.2 AND pressure_state IS NULL;
    SELECT IF(v_ok = 1, 'TEST 3 PASS: weather day without pressure row kept',
                        'TEST 3 FAIL: weather day without pressure row lost') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 4: v_water_day carries the daily means the forecast plot draws (discharge, level, turbidity)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_04 //
CREATE PROCEDURE test_04()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 4 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'R04', NULL);
    INSERT INTO water_reading_day (station_id, dt, n, q_n, q_mean, level_mean, turbidity_mean, oxygen_mean, ph_mean, stamp)
    VALUES (90001, UTC_DATE() - INTERVAL 2 DAY, 24, 24, 12.5, 1.25, 3.5, 9.1, 7.60, UTC_TIMESTAMP());
    SELECT COUNT(*) INTO v_ok FROM v_water_day
     WHERE sid = 90001 AND dt = UTC_DATE() - INTERVAL 2 DAY AND discharge = 12.5 AND level = 1.25 AND turbidity = 3.5
       AND oxygen = 9.1 AND ph = 7.60 AND readings = 24;
    SELECT IF(v_ok = 1, 'TEST 4 PASS: v_water_day has the daily means by sid and date',
                        'TEST 4 FAIL: v_water_day wrong') AS message;
    ROLLBACK;
END //

DELIMITER ;

CALL test_01();
CALL test_02();
CALL test_03();
CALL test_04();

DROP PROCEDURE IF EXISTS test_01;
DROP PROCEDURE IF EXISTS test_02;
DROP PROCEDURE IF EXISTS test_03;
DROP PROCEDURE IF EXISTS test_04;
DROP PROCEDURE IF EXISTS t_station;
