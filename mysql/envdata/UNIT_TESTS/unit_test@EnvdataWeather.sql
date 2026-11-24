-- MySQL envdata unit tests: weather payloads (sp_weather_save), NWS station cache, provider coverage,
-- the weather due view and v_station_day. One PROCEDURE per test, own handler, own transaction, ROLLBACK.
SET NAMES utf8mb4;

DELIMITER //

DROP PROCEDURE IF EXISTS t_station //
CREATE PROCEDURE t_station(IN p_sid INT, IN p_mli VARCHAR(64), IN p_country CHAR(2), IN p_has_fish TINYINT)
BEGIN
    INSERT INTO station (station_id, mli, ws_id, country, state, lat, lon, loc_name, master_stamp, mirror_stamp, has_fish)
    VALUES (p_sid, p_mli, UUID(), p_country, 'ON', 45, -79, 'test', UTC_TIMESTAMP(), UTC_TIMESTAMP(), p_has_fish);
END //

-- ----------------------------------------------------------------
-- TEST 1: a canonical payload is shredded into one weather_day row per date
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_01 //
CREATE PROCEDURE test_01()
BEGIN
    DECLARE v_days INT;
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 1 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'W01', 'CA', 1);
    CALL sp_weather_save('W01', 2, '{"schema":"fishfind.weather.forecast/v1","days":[
        {"date":"2026-11-24","time":"12:00:00","tempHighC":5.5,"tempLowC":-1,"tempDayC":3,"humidityPct":80,
         "windSpeedKmh":12,"windDegrees":270,"windDirection":"W","precipChancePct":40,"precipMm":2,
         "weatherCode":61,"icon":"rain","conditionsShort":"Rain","conditionsLong":"Light rain"},
        {"date":"2026-11-25","tempHighC":3}]}', v_days);
    SELECT COUNT(*) INTO v_ok FROM weather_day
     WHERE station_id = 90001 AND ((dt = '2026-11-24' AND tm = '12:00:00' AND tm_high = 5.5 AND tm_low = -1 AND pop = 40
            AND weather_code = 61 AND short_text = 'Rain' AND gpf_day = 0 AND provider_type = 2)
        OR (dt = '2026-11-25' AND tm_high = 3 AND tm_low IS NULL));
    SELECT IF(v_days = 2 AND v_ok = 2, 'TEST 1 PASS: canonical payload shredded, one row per date',
                                       'TEST 1 FAIL: canonical payload not shredded') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 2: pressureHpa is stored in mm Hg (1013 hPa -> 759.8 mm)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_02 //
CREATE PROCEDURE test_02()
BEGIN
    DECLARE v_days INT;
    DECLARE v_mm DECIMAL(5,1);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 2 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'W02', 'CA', 1);
    CALL sp_weather_save('W02', 2, '{"schema":"fishfind.weather.forecast/v1",
        "days":[{"date":"2026-11-24","pressureHpa":1013}]}', v_days);
    SELECT pressure_mm INTO v_mm FROM weather_day WHERE station_id = 90001;
    SELECT IF(v_mm = 759.8, 'TEST 2 PASS: 1013 hPa stored as 759.8 mm Hg',
                            'TEST 2 FAIL: pressure not converted to mm Hg') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 3: a later payload without pressure / tempHigh keeps the stored ones; others are replaced
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_03 //
CREATE PROCEDURE test_03()
BEGIN
    DECLARE v_days INT;
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 3 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'W03', 'CA', 1);
    CALL sp_weather_save('W03', 2, '{"schema":"fishfind.weather.forecast/v1",
        "days":[{"date":"2026-11-24","pressureHpa":1013,"tempHighC":5,"precipChancePct":40}]}', v_days);
    CALL sp_weather_save('W03', 5, '{"schema":"fishfind.weather.forecast/v1",
        "days":[{"date":"2026-11-24","precipChancePct":10}]}', v_days);
    SELECT COUNT(*) INTO v_ok FROM weather_day
     WHERE station_id = 90001 AND pressure_mm = 759.8 AND tm_high = 5 AND pop = 10 AND provider_type = 5;
    SELECT IF(v_ok = 1, 'TEST 3 PASS: missing pressure/tempHigh keep stored values',
                        'TEST 3 FAIL: COALESCE rules of the upsert broken') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 4: an unknown envelope or invalid JSON is stored raw and not shredded
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_04 //
CREATE PROCEDURE test_04()
BEGIN
    DECLARE v_d1 INT;
    DECLARE v_d2 INT;
    DECLARE v_raw INT;
    DECLARE v_rows INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 4 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'W04', 'CA', 1);
    CALL sp_weather_save('W04', 2, '{"schema":"fishfind.weather.forecast/v9","days":[{"date":"2026-11-24"}]}', v_d1);
    CALL sp_weather_save('W04', 1, 'not { json', v_d2);
    SELECT COUNT(*) INTO v_raw FROM weather_raw WHERE station_id = 90001 AND payload = 'not { json' AND provider_type = 1;
    SELECT COUNT(*) INTO v_rows FROM weather_day WHERE station_id = 90001;
    SELECT IF(v_d1 = -1 AND v_d2 = -1 AND v_raw = 1 AND v_rows = 0,
              'TEST 4 PASS: unknown or invalid payload stored raw, not shredded',
              'TEST 4 FAIL: unknown or invalid payload mishandled') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 5: a payload that fails to shred still keeps its raw row and weather_stamp
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_05 //
CREATE PROCEDURE test_05()
BEGIN
    DECLARE v_d INT;
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 5 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'W05', 'CA', 1);
    CALL sp_weather_save('W05', 2, '{"schema":"fishfind.weather.forecast/v1",
        "days":[{"date":"2026-11-24","weatherCode":"not a number"}]}', v_d);
    SELECT COUNT(*) INTO v_ok FROM weather_raw r JOIN station s ON s.station_id = r.station_id
     WHERE r.station_id = 90001 AND s.weather_stamp IS NOT NULL;
    SELECT IF(v_ok = 1, 'TEST 5 PASS: a bad day never loses the raw payload',
                        'TEST 5 FAIL: the raw payload was lost') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 6: an unknown station mli is rejected with SQLSTATE 45000
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_06 //
CREATE PROCEDURE test_06()
BEGIN
    DECLARE v_err INT DEFAULT 0;
    DECLARE v_d INT;
    DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' SET v_err = v_err + 1;
    START TRANSACTION;
    CALL sp_weather_save('W06-NOPE', 2, '{}', v_d);
    CALL sp_weather_gov_station_save('W06-NOPE', 1, 2, 'KXYZ');
    CALL sp_provider_coverage_save('W06-NOPE', 'open', 1);
    SELECT IF(v_err = 3, 'TEST 6 PASS: unknown mli raises 45000 in the weather writers',
                         'TEST 6 FAIL: unknown mli was not rejected') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 7: NWS cache: NULL = asked, nothing nearby (a row); a later answer replaces it
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_07 //
CREATE PROCEDURE test_07()
BEGIN
    DECLARE v_null INT;
    DECLARE v_set INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 7 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90002, 'W07', 'US', 1);
    CALL sp_weather_gov_station_save('W07', 43, -88, NULL);
    SELECT COUNT(*) INTO v_null FROM v_weather_gov_station WHERE mli = 'W07' AND station_id IS NULL;
    CALL sp_weather_gov_station_save('W07', 43.1, -88, 'KMKE');
    SELECT COUNT(*) INTO v_set FROM v_weather_gov_station WHERE mli = 'W07' AND station_id = 'KMKE' AND lat = 43.1;
    SELECT IF(v_null = 1 AND v_set = 1, 'TEST 7 PASS: NWS cache keeps the negative answer, then updates',
                                        'TEST 7 FAIL: NWS station cache wrong') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 8: provider coverage is one current fact per (station, provider)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_08 //
CREATE PROCEDURE test_08()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 8 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'W08', 'CA', 1);
    CALL sp_provider_coverage_save('W08', 'weather-canada', 0);
    CALL sp_provider_coverage_save('W08', 'weather-canada', 1);
    CALL sp_provider_coverage_save('W08', 'open', 0);
    SELECT COUNT(*) INTO v_ok FROM v_provider_coverage
     WHERE mli = 'W08' AND ((provider = 'weather-canada' AND covered = 1) OR (provider = 'open' AND covered = 0));
    SELECT IF(v_ok = 2 AND (SELECT COUNT(*) FROM provider_coverage WHERE station_id = 90001) = 2,
              'TEST 8 PASS: coverage upserted per station and provider',
              'TEST 8 FAIL: coverage not upserted') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 9: weather due = fish stations only; back-off ones only when none is free
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_09 //
CREATE PROCEDURE test_09()
BEGIN
    DECLARE v_a INT;
    DECLARE v_b INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 9 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    -- this test needs the fish stations to itself
    UPDATE station SET has_fish = 0;
    CALL t_station(90001, 'W09A', 'CA', 1);
    CALL t_station(90002, 'W09B', 'CA', 1);
    CALL t_station(90003, 'W09C', 'CA', 0);
    UPDATE station SET backoff_state = 2 WHERE station_id = 90002;
    SELECT COUNT(*) INTO v_a FROM v_station_weather_due WHERE mli = 'W09A' AND flag = 1;
    SET v_a = v_a + (SELECT COUNT(*) FROM v_station_weather_due WHERE mli IN ('W09B', 'W09C'));
    UPDATE station SET backoff_state = 1 WHERE station_id = 90001;
    SELECT COUNT(*) INTO v_b FROM v_station_weather_due WHERE flag = 0 AND mli IN ('W09A', 'W09B');
    SELECT IF(v_a = 1 AND v_b = 2, 'TEST 9 PASS: fish stations due; back-off only as fallback',
                                   'TEST 9 FAIL: weather due view wrong') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 10: v_station_day covers 3 days back .. 15 ahead and joins the pressure state
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_10 //
CREATE PROCEDURE test_10()
BEGIN
    DECLARE v_in INT;
    DECLARE v_out INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 10 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_station(90001, 'W10', 'CA', 1);
    INSERT INTO weather_day (station_id, dt, pressure_mm, provider_type, stamp) VALUES
        (90001, UTC_DATE() - INTERVAL 4 DAY, 760, 2, UTC_TIMESTAMP()),
        (90001, UTC_DATE() - INTERVAL 3 DAY, 760, 2, UTC_TIMESTAMP()),
        (90001, UTC_DATE() + INTERVAL 15 DAY, 760, 2, UTC_TIMESTAMP()),
        (90001, UTC_DATE() + INTERVAL 16 DAY, 760, 2, UTC_TIMESTAMP());
    INSERT INTO station_pressure_day (station_id, dt, pressure_mm, state, weight, stamp)
    VALUES (90001, UTC_DATE() - INTERVAL 3 DAY, 755.5, 'FRONT', 0.6, UTC_TIMESTAMP());
    SELECT COUNT(*) INTO v_in FROM v_station_day WHERE sid = 90001
       AND ((dt = UTC_DATE() - INTERVAL 3 DAY AND pressure_state = 'FRONT' AND pressure_mm = 755.5 AND pressure_weight = 0.6)
         OR (dt = UTC_DATE() + INTERVAL 15 DAY AND pressure_state IS NULL AND pressure_mm = 760));
    SELECT COUNT(*) INTO v_out FROM v_station_day WHERE sid = 90001;
    SELECT IF(v_in = 2 AND v_out = 2, 'TEST 10 PASS: v_station_day spans -3..+15 with pressure state',
                                      'TEST 10 FAIL: v_station_day window or join wrong') AS message;
    ROLLBACK;
END //

DELIMITER ;

CALL test_01();
CALL test_02();
CALL test_03();
CALL test_04();
CALL test_05();
CALL test_06();
CALL test_07();
CALL test_08();
CALL test_09();
CALL test_10();

DROP PROCEDURE IF EXISTS test_01;
DROP PROCEDURE IF EXISTS test_02;
DROP PROCEDURE IF EXISTS test_03;
DROP PROCEDURE IF EXISTS test_04;
DROP PROCEDURE IF EXISTS test_05;
DROP PROCEDURE IF EXISTS test_06;
DROP PROCEDURE IF EXISTS test_07;
DROP PROCEDURE IF EXISTS test_08;
DROP PROCEDURE IF EXISTS test_09;
DROP PROCEDURE IF EXISTS test_10;
DROP PROCEDURE IF EXISTS t_station;
