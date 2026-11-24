-- MySQL envdata unit tests: sp_fill_pressure_state (port of MSSQL fn_station_pressure_days, rules in mm Hg).
-- Each test seeds daily pressure for one station from 2026-11-15 (values[i] = day i, mm Hg, null = none) and runs
-- the fill as of 2026-11-24 12:00 with 7 days ahead (window 2026-11-21 .. 2026-12-01).
-- One PROCEDURE per test, own handler, own transaction, ROLLBACK.
SET NAMES utf8mb4;

DELIMITER //

DROP PROCEDURE IF EXISTS t_p_station //
CREATE PROCEDURE t_p_station(IN p_sid INT, IN p_mli VARCHAR(64), IN p_lat DOUBLE)
BEGIN
    INSERT INTO station (station_id, mli, ws_id, country, state, lat, lon, loc_name, master_stamp, mirror_stamp, has_fish)
    VALUES (p_sid, p_mli, UUID(), 'CA', 'ON', p_lat, -79, 'test', UTC_TIMESTAMP(), UTC_TIMESTAMP(), 1);
END //

-- seeds weather_day.pressure_mm (and tm_high, when given) directly, one row per value from p_start
DROP PROCEDURE IF EXISTS t_p_seed //
CREATE PROCEDURE t_p_seed(IN p_sid INT, IN p_start DATE, IN p_mm JSON, IN p_tm_high DOUBLE)
BEGIN
    INSERT INTO weather_day (station_id, dt, pressure_mm, tm_high, provider_type, stamp)
    SELECT p_sid, p_start + INTERVAL (j.i - 1) DAY, j.mm, p_tm_high, 2, UTC_TIMESTAMP()
      FROM JSON_TABLE(p_mm, '$[*]' COLUMNS (i FOR ORDINALITY, mm DECIMAL(5,1) PATH '$')) j;
END //

-- seeds through sp_weather_save from whole hPa, as the weather service sends them (pressureHpa)
DROP PROCEDURE IF EXISTS t_p_seed_hpa //
CREATE PROCEDURE t_p_seed_hpa(IN p_mli VARCHAR(64), IN p_start DATE, IN p_hpa JSON)
BEGIN
    DECLARE v_days INT;
    DECLARE v_json TEXT;
    SELECT JSON_OBJECT('schema', 'fishfind.weather.forecast/v1',
                       'days', JSON_ARRAYAGG(JSON_OBJECT('date', DATE_FORMAT(p_start + INTERVAL (j.i - 1) DAY, '%Y-%m-%d'),
                                                         'pressureHpa', j.h)))
      INTO v_json
      FROM JSON_TABLE(p_hpa, '$[*]' COLUMNS (i FOR ORDINALITY, h INT PATH '$')) j;
    CALL sp_weather_save(p_mli, 2, v_json, v_days);
END //

DROP PROCEDURE IF EXISTS t_p_fill //
CREATE PROCEDURE t_p_fill(IN p_mli VARCHAR(64), IN p_at DATETIME, OUT p_n INT)
BEGIN
    CALL sp_fill_pressure_state(p_at, p_mli, 0, 7, p_n);
END //

-- ----------------------------------------------------------------
-- TEST 1: a 6 mm low is a FRONT, counted PRE_3 .. POST_3 around it, strength 1 at a 12 mm swing
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_01 //
CREATE PROCEDURE test_01()
BEGIN
    DECLARE v_n INT;
    DECLARE v_states VARCHAR(255);
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 1 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_p_station(90001, 'P01', 45);
    CALL t_p_seed(90001, '2026-11-15', '[760,760,760,760,760,760,760,760,757,754,757.5,760,760,760,760,760,760,760,760,760,760,760,760]', NULL);
    CALL t_p_fill('P01', '2026-11-24 12:00:00', v_n);
    SELECT GROUP_CONCAT(state ORDER BY dt) INTO v_states FROM station_pressure_day
     WHERE station_id = 90001 AND dt BETWEEN '2026-11-21' AND '2026-11-28';
    SELECT COUNT(*) INTO v_ok FROM station_pressure_day
     WHERE station_id = 90001 AND dt = '2026-11-24' AND front_dt = '2026-11-24' AND swing_mm = 12.0
       AND strength = 1.00 AND d1_mm = -3.0 AND pressure_mm = 754.0;
    SELECT IF(v_n = 11 AND v_ok = 1 AND v_states = 'PRE_3,PRE_2,PRE_1,FRONT,POST_1,POST_2,POST_3,STABLE',
              'TEST 1 PASS: 6 mm low is a FRONT with PRE_3..POST_3 around it',
              'TEST 1 FAIL: front cycle states wrong') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 2: exactly 4.5 mm fall and 3.0 mm rise is a FRONT, strength 0.50 at a 7.5 mm swing
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_02 //
CREATE PROCEDURE test_02()
BEGIN
    DECLARE v_n INT;
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 2 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_p_station(90001, 'P02', 45);
    CALL t_p_seed(90001, '2026-11-15', '[760,760,760,760,760,760,760,760,760,755.5,758.5,758.5,760,760,760,760,760,760,760,760,760,760,760]', NULL);
    CALL t_p_fill('P02', '2026-11-24 12:00:00', v_n);
    SELECT COUNT(*) INTO v_ok FROM station_pressure_day
     WHERE station_id = 90001 AND dt = '2026-11-24' AND state = 'FRONT' AND swing_mm = 7.5 AND strength = 0.50;
    SELECT IF(v_ok = 1, 'TEST 2 PASS: 4.5 mm fall + 3.0 mm rise is a FRONT, strength 0.5',
                        'TEST 2 FAIL: the exact 4.5 / 3.0 mm thresholds missed') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 3: a 4.4 mm fall is no front; the day is FALLING (<= -3.0 mm)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_03 //
CREATE PROCEDURE test_03()
BEGIN
    DECLARE v_n INT;
    DECLARE v_s VARCHAR(8);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 3 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_p_station(90001, 'P03', 45);
    CALL t_p_seed(90001, '2026-11-15', '[760,760,760,760,760,760,760,760,760,755.6,758.6,758.6,760,760,760,760,760,760,760,760,760,760,760]', NULL);
    CALL t_p_fill('P03', '2026-11-24 12:00:00', v_n);
    SELECT state INTO v_s FROM station_pressure_day WHERE station_id = 90001 AND dt = '2026-11-24';
    SELECT IF(v_s = 'FALLING', 'TEST 3 PASS: a 4.4 mm fall is no front, the day is FALLING',
                               'TEST 3 FAIL: a 4.4 mm fall was read as a front') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 4: whole-hPa input keeps the MSSQL front boundary: 6/4 hPa is a front, 5 hPa is not
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_04 //
CREATE PROCEDURE test_04()
BEGIN
    DECLARE v_n INT;
    DECLARE v_a VARCHAR(8);
    DECLARE v_b VARCHAR(8);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 4 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_p_station(90001, 'P04A', 45);
    CALL t_p_station(90002, 'P04B', 45);
    CALL t_p_seed_hpa('P04A', '2026-11-15', '[1013,1013,1013,1013,1013,1013,1013,1013,1013,1007,1011,1011,1013,1013,1013,1013,1013,1013,1013,1013,1013,1013,1013]');
    CALL t_p_seed_hpa('P04B', '2026-11-15', '[1013,1013,1013,1013,1013,1013,1013,1013,1013,1008,1011,1011,1013,1013,1013,1013,1013,1013,1013,1013,1013,1013,1013]');
    CALL t_p_fill('P04A', '2026-11-24 12:00:00', v_n);
    CALL t_p_fill('P04B', '2026-11-24 12:00:00', v_n);
    SELECT state INTO v_a FROM station_pressure_day WHERE station_id = 90001 AND dt = '2026-11-24';
    SELECT state INTO v_b FROM station_pressure_day WHERE station_id = 90002 AND dt = '2026-11-24';
    SELECT IF(v_a = 'FRONT' AND v_b = 'FALLING', 'TEST 4 PASS: hPa 6/4 front boundary unchanged in mm Hg',
                                                'TEST 4 FAIL: mm Hg rules disagree with the hPa ones') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 5: strength is linear between 7.5 and 11.25 mm: a 9.4 mm swing is 0.75
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_05 //
CREATE PROCEDURE test_05()
BEGIN
    DECLARE v_n INT;
    DECLARE v_s DECIMAL(3,2);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 5 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_p_station(90001, 'P05', 45);
    CALL t_p_seed(90001, '2026-11-15', '[760,760,760,760,760,760,760,760,760,755.3,760,760,760,760,760,760,760,760,760,760,760,760,760]', NULL);
    CALL t_p_fill('P05', '2026-11-24 12:00:00', v_n);
    SELECT strength INTO v_s FROM station_pressure_day WHERE station_id = 90001 AND dt = '2026-11-24' AND state = 'FRONT';
    SELECT IF(v_s = 0.75, 'TEST 5 PASS: a 9.4 mm swing has strength 0.75',
                          'TEST 5 FAIL: strength is not linear 7.5 .. 11.25 mm') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 6: without a front, +3.0 mm in a day is RISING, then STABLE
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_06 //
CREATE PROCEDURE test_06()
BEGIN
    DECLARE v_n INT;
    DECLARE v_states VARCHAR(64);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 6 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_p_station(90001, 'P06', 45);
    CALL t_p_seed(90001, '2026-11-15', '[760,760,760,760,760,760,760,760,760,763,763,763,763,763,763,763,763,763,763,763,763,763,763]', NULL);
    CALL t_p_fill('P06', '2026-11-24 12:00:00', v_n);
    SELECT GROUP_CONCAT(state ORDER BY dt) INTO v_states FROM station_pressure_day
     WHERE station_id = 90001 AND dt BETWEEN '2026-11-23' AND '2026-11-25';
    SELECT IF(v_states = 'STABLE,RISING,STABLE', 'TEST 6 PASS: +3.0 mm without a front is RISING',
                                                 'TEST 6 FAIL: RISING / STABLE wrong') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 7: fewer than 5 of the 7 days around a day have pressure: no state, no strength
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_07 //
CREATE PROCEDURE test_07()
BEGIN
    DECLARE v_n INT;
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 7 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_p_station(90001, 'P07', 45);
    CALL t_p_seed(90001, '2026-11-23', '[760,754,760,760]', NULL);
    CALL t_p_fill('P07', '2026-11-24 12:00:00', v_n);
    SELECT COUNT(*) INTO v_ok FROM station_pressure_day
     WHERE station_id = 90001 AND dt = '2026-11-24' AND state IS NULL AND strength IS NULL AND pressure_mm = 754;
    SELECT IF(v_ok = 1, 'TEST 7 PASS: 4 of 7 days with pressure gives no state',
                        'TEST 7 FAIL: thin pressure data still gave a state') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 8: season: 0.6 in a northern summer, so weight = strength x 0.6
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_08 //
CREATE PROCEDURE test_08()
BEGIN
    DECLARE v_n INT;
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 8 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_p_station(90001, 'P08', 45);
    CALL t_p_seed(90001, '2026-07-06', '[760,760,760,760,760,760,760,760,760,755.3,760,760,760,760,760,760,760,760,760,760,760,760,760]', 25);
    CALL t_p_fill('P08', '2026-07-15 12:00:00', v_n);
    SELECT COUNT(*) INTO v_ok FROM station_pressure_day
     WHERE station_id = 90001 AND dt = '2026-07-15' AND state = 'FRONT' AND season = 0.60 AND weight = 0.45;
    SELECT IF(v_ok = 1, 'TEST 8 PASS: a July front has season 0.6, weight 0.75 x 0.6',
                        'TEST 8 FAIL: summer season weight wrong') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 9: season: 0.4 under ice (no day above 0 degC in the 5 days, >= 3 known)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_09 //
CREATE PROCEDURE test_09()
BEGIN
    DECLARE v_n INT;
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 9 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_p_station(90001, 'P09', 45);
    CALL t_p_seed(90001, '2026-11-15', '[760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760]', -5);
    CALL t_p_fill('P09', '2026-11-24 12:00:00', v_n);
    SELECT COUNT(*) INTO v_ok FROM station_pressure_day
     WHERE station_id = 90001 AND dt = '2026-11-24' AND state = 'STABLE' AND season = 0.40 AND weight = 0.40;
    SELECT IF(v_ok = 1, 'TEST 9 PASS: 5 frozen days give season 0.4',
                        'TEST 9 FAIL: ice season weight wrong') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 10: unknown highs are not "frozen": with no tm_high the season stays 1.0
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_10 //
CREATE PROCEDURE test_10()
BEGIN
    DECLARE v_n INT;
    DECLARE v_season DECIMAL(3,2);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 10 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_p_station(90001, 'P10', 45);
    CALL t_p_seed(90001, '2026-11-15', '[760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760,760]', NULL);
    CALL t_p_fill('P10', '2026-11-24 12:00:00', v_n);
    SELECT season INTO v_season FROM station_pressure_day WHERE station_id = 90001 AND dt = '2026-11-24';
    SELECT IF(v_season = 1.00, 'TEST 10 PASS: unknown highs leave season 1.0',
                               'TEST 10 FAIL: unknown highs read as ice') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 11: a window row the run no longer produces is deleted; older history is kept
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_11 //
CREATE PROCEDURE test_11()
BEGIN
    DECLARE v_n INT;
    DECLARE v_in INT;
    DECLARE v_old INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 11 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_p_station(90001, 'P11', 45);
    INSERT INTO station_pressure_day (station_id, dt, pressure_mm, state, stamp) VALUES
        (90001, '2026-11-25', 760, 'STABLE', UTC_TIMESTAMP()), (90001, '2026-11-15', 760, 'STABLE', UTC_TIMESTAMP());
    CALL t_p_fill('P11', '2026-11-24 12:00:00', v_n);
    SELECT COUNT(*) INTO v_in FROM station_pressure_day WHERE station_id = 90001 AND dt = '2026-11-25';
    SELECT COUNT(*) INTO v_old FROM station_pressure_day WHERE station_id = 90001 AND dt = '2026-11-15';
    SELECT IF(v_n = 0 AND v_in = 0 AND v_old = 1, 'TEST 11 PASS: stale window row deleted, history kept',
                                                 'TEST 11 FAIL: stale window rows or history mishandled') AS message;
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
CALL test_11();

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
DROP PROCEDURE IF EXISTS test_11;
DROP PROCEDURE IF EXISTS t_p_station;
DROP PROCEDURE IF EXISTS t_p_seed;
DROP PROCEDURE IF EXISTS t_p_seed_hpa;
DROP PROCEDURE IF EXISTS t_p_fill;
