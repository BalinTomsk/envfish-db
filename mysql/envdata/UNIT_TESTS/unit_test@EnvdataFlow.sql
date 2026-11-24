-- MySQL envdata unit tests: sp_fill_water_reading_day + sp_fill_flow_state (port of MSSQL fn_station_flow_state).
-- Each test seeds 30 days of daily discharge for one station (one reading per day at 06:00 UTC; values[i] = day i
-- before 2026-11-24, null = no reading), aggregates them and asserts the flow state the rules give.
-- One PROCEDURE per test, own handler, own transaction, ROLLBACK.
SET NAMES utf8mb4;

DELIMITER //

DROP PROCEDURE IF EXISTS t_flow_seed //
CREATE PROCEDURE t_flow_seed(IN p_sid INT, IN p_mli VARCHAR(64), IN p_values JSON)
BEGIN
    DECLARE v_n INT;
    INSERT INTO station (station_id, mli, ws_id, country, state, lat, lon, loc_name, master_stamp, mirror_stamp, has_fish)
    VALUES (p_sid, p_mli, UUID(), 'CA', 'ON', 45, -79, 'test', UTC_TIMESTAMP(), UTC_TIMESTAMP(), 1);
    INSERT INTO water_reading (station_id, ts, discharge)
    SELECT p_sid, TIMESTAMP('2026-11-24 06:00:00') - INTERVAL (j.i - 1) DAY, j.q
      FROM JSON_TABLE(p_values, '$[*]' COLUMNS (i FOR ORDINALITY, q DOUBLE PATH '$')) j
     WHERE j.q IS NOT NULL;
    INSERT INTO station_current (station_id, ts, iter_stamp, flow_state)
    VALUES (p_sid, '2026-11-24 06:00:00', UTC_TIMESTAMP(), 'OLD');
    CALL sp_fill_water_reading_day('2026-10-20', '2026-11-24', p_mli, v_n);
END //

-- the state sp_fill_flow_state gives the seeded station as of 2026-11-24 12:00
DROP PROCEDURE IF EXISTS t_flow_state //
CREATE PROCEDURE t_flow_state(IN p_sid INT, IN p_mli VARCHAR(64), OUT p_state VARCHAR(10))
BEGIN
    DECLARE v_n INT;
    CALL sp_fill_flow_state('2026-11-24 12:00:00', p_mli, 0, v_n);
    SELECT COALESCE(flow_state, 'NULL') INTO p_state FROM station_current WHERE station_id = p_sid;
END //

-- ----------------------------------------------------------------
-- TEST 1: steady flow is STABLE
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_01 //
CREATE PROCEDURE test_01()
BEGIN
    DECLARE v_s VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 1 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F01', '[10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10]');
    CALL t_flow_state(90001, 'F01', v_s);
    SELECT IF(v_s = 'STABLE', 'TEST 1 PASS: steady flow is STABLE', 'TEST 1 FAIL: steady flow is not STABLE') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 2: day 0 at 2.5 x day 1 and >= 2 x median is SPATE
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_02 //
CREATE PROCEDURE test_02()
BEGIN
    DECLARE v_s VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 2 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F02', '[25,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10]');
    CALL t_flow_state(90001, 'F02', v_s);
    SELECT IF(v_s = 'SPATE', 'TEST 2 PASS: a sudden 2.5x flood is SPATE', 'TEST 2 FAIL: a 2.5x flood is not SPATE') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 3: day 0 at 1.2 x day 1 is RISING
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_03 //
CREATE PROCEDURE test_03()
BEGIN
    DECLARE v_s VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 3 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F03', '[12,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10]');
    CALL t_flow_state(90001, 'F03', v_s);
    SELECT IF(v_s = 'RISING', 'TEST 3 PASS: a 1.2x day-on-day rise is RISING', 'TEST 3 FAIL: a 1.2x rise is not RISING') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 4: a peak 2 days ago, day 0 still >= 1.5 x median, is DROPPING
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_04 //
CREATE PROCEDURE test_04()
BEGIN
    DECLARE v_s VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 4 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F04', '[20,30,40,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10]');
    CALL t_flow_state(90001, 'F04', v_s);
    SELECT IF(v_s = 'DROPPING', 'TEST 4 PASS: high water clearing after a peak is DROPPING',
                                'TEST 4 FAIL: high water after a peak is not DROPPING') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 5: a peak 2 days ago, day 0 back under 1.5 x median, is SETTLED
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_05 //
CREATE PROCEDURE test_05()
BEGIN
    DECLARE v_s VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 5 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F05', '[12,20,40,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10]');
    CALL t_flow_state(90001, 'F05', v_s);
    SELECT IF(v_s = 'SETTLED', 'TEST 5 PASS: back to normal after a peak is SETTLED',
                               'TEST 5 FAIL: back to normal after a peak is not SETTLED') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 6: days 0..2 at <= 0.5 x median is LOW
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_06 //
CREATE PROCEDURE test_06()
BEGIN
    DECLARE v_s VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 6 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F06', '[4,4,4,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10]');
    CALL t_flow_state(90001, 'F06', v_s);
    SELECT IF(v_s = 'LOW', 'TEST 6 PASS: three days at 0.4x median is LOW', 'TEST 6 FAIL: 0.4x median is not LOW') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 7: day 0 at 0.8 x the mean of days 3..7 is FALLING
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_07 //
CREATE PROCEDURE test_07()
BEGIN
    DECLARE v_s VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 7 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F07', '[8,8,8,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10]');
    CALL t_flow_state(90001, 'F07', v_s);
    SELECT IF(v_s = 'FALLING', 'TEST 7 PASS: 0.8x of days 3..7 is FALLING', 'TEST 7 FAIL: 0.8x of days 3..7 not FALLING') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 8: the 30-day median of an even count is the mean of the middle two (PERCENTILE_CONT)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_08 //
CREATE PROCEDURE test_08()
BEGIN
    DECLARE v_m DOUBLE;
    DECLARE v_s VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 8 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F08', '[30,29,28,27,26,25,24,23,22,21,20,19,18,17,16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1]');
    CALL t_flow_state(90001, 'F08', v_s);
    SELECT q_median_30d INTO v_m FROM station_current WHERE station_id = 90001;
    SELECT IF(v_m = 15.5, 'TEST 8 PASS: median of 1..30 is 15.5', 'TEST 8 FAIL: even-count median is wrong') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 9: the median of an odd count is the middle value; ratios are q0 / day n
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_09 //
CREATE PROCEDURE test_09()
BEGIN
    DECLARE v_ok INT;
    DECLARE v_s VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 9 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F09', '[12,10,8,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,null]');
    CALL t_flow_state(90001, 'F09', v_s);
    SELECT COUNT(*) INTO v_ok FROM station_current
     WHERE station_id = 90001 AND q_median_30d = 10 AND ABS(q_ratio_1d - 1.2) < 1e-9 AND ABS(q_ratio_2d - 1.5) < 1e-9
       AND ABS(q_ratio_3_7d - 1.2) < 1e-9 AND flow_stamp IS NOT NULL;
    SELECT IF(v_ok = 1, 'TEST 9 PASS: odd-count median and the three ratios are right',
                        'TEST 9 FAIL: odd-count median or ratios wrong') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 10: too thin (3 of days 0..7) gives no state, and the old state is cleared
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_10 //
CREATE PROCEDURE test_10()
BEGIN
    DECLARE v_s VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 10 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F10', '[10,10,10,null,null,null,null,null,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10]');
    CALL t_flow_state(90001, 'F10', v_s);
    SELECT IF(v_s = 'NULL', 'TEST 10 PASS: 3 of 8 days gives no state, old state cleared',
                            'TEST 10 FAIL: thin data kept or gave a state') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 11: a negative reading in the 30 days (tidal gauge) gives no state
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_11 //
CREATE PROCEDURE test_11()
BEGIN
    DECLARE v_s VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 11 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F11', '[10,10,10,10,10,10,10,10,10,10,-3,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10]');
    CALL t_flow_state(90001, 'F11', v_s);
    SELECT IF(v_s = 'NULL', 'TEST 11 PASS: a negative reading gives no state',
                            'TEST 11 FAIL: a negative reading still gave a state') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 12: day 0 more than 20 x day 1 (a glitch) gives no state
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_12 //
CREATE PROCEDURE test_12()
BEGIN
    DECLARE v_s VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 12 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F12', '[250,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10]');
    CALL t_flow_state(90001, 'F12', v_s);
    SELECT IF(v_s = 'NULL', 'TEST 12 PASS: day 0 at 25x day 1 is a glitch, no state',
                            'TEST 12 FAIL: a 25x glitch gave a state') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 13: a last reading older than 2 days gives no state (stale gauge)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_13 //
CREATE PROCEDURE test_13()
BEGIN
    DECLARE v_s VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 13 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F13', '[null,null,null,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10]');
    CALL t_flow_state(90001, 'F13', v_s);
    SELECT IF(v_s = 'NULL', 'TEST 13 PASS: last reading 3 days old gives no state',
                            'TEST 13 FAIL: a stale gauge gave a state') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 14: a full run is skipped (0) while a flow_stamp is younger than p_max_age_hours
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_14 //
CREATE PROCEDURE test_14()
BEGIN
    DECLARE v_n INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 14 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F14', '[10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10]');
    UPDATE station_current SET flow_stamp = UTC_TIMESTAMP() - INTERVAL 1 HOUR WHERE station_id = 90001;
    CALL sp_fill_flow_state('2026-11-24 12:00:00', NULL, 6, v_n);
    SELECT IF(v_n = 0 AND (SELECT flow_state FROM station_current WHERE station_id = 90001) = 'OLD',
              'TEST 14 PASS: a run within the age window is skipped',
              'TEST 14 FAIL: the age guard did not skip the run') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 15: the daily aggregate averages a day's readings and keeps the last discharge time
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_15 //
CREATE PROCEDURE test_15()
BEGIN
    DECLARE v_ok INT;
    DECLARE v_n INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 15 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    INSERT INTO station (station_id, mli, ws_id, country, lat, lon, loc_name, master_stamp, mirror_stamp)
    VALUES (90001, 'F15', UUID(), 'CA', 45, -79, 'test', UTC_TIMESTAMP(), UTC_TIMESTAMP());
    INSERT INTO water_reading (station_id, ts, discharge, elevation) VALUES
        (90001, '2026-11-24 01:00:00', 10, 1.0), (90001, '2026-11-24 13:00:00', 20, 2.0),
        (90001, '2026-11-24 23:00:00', NULL, 3.0);
    CALL sp_fill_water_reading_day('2026-11-24', '2026-11-24', 'F15', v_n);
    SELECT COUNT(*) INTO v_ok FROM water_reading_day
     WHERE station_id = 90001 AND dt = '2026-11-24' AND n = 3 AND q_n = 2 AND q_mean = 15 AND q_min = 10
       AND q_max = 20 AND q_last_ts = '2026-11-24 13:00:00' AND level_mean = 2;
    SELECT IF(v_ok = 1 AND v_n = 1, 'TEST 15 PASS: daily aggregate means, extremes, last time',
                                    'TEST 15 FAIL: daily aggregate wrong') AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 16: the fills read at READ COMMITTED but give the caller its own isolation level back
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_16 //
CREATE PROCEDURE test_16()
BEGIN
    DECLARE v_n INT;
    DECLARE v_s VARCHAR(10);
    DECLARE v_before VARCHAR(32) DEFAULT @@SESSION.transaction_isolation;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'TEST 16 FAIL: unexpected SQL error' AS message; END;
    START TRANSACTION;
    CALL t_flow_seed(90001, 'F16', '[10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10]');
    CALL t_flow_state(90001, 'F16', v_s);
    CALL sp_fill_pressure_state('2026-11-24 12:00:00', 'F16', 0, 7, v_n);
    SELECT IF(@@SESSION.transaction_isolation = v_before AND v_s = 'STABLE',
              'TEST 16 PASS: fills restore the caller isolation level',
              'TEST 16 FAIL: a fill left the session isolation changed') AS message;
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
CALL test_12();
CALL test_13();
CALL test_14();
CALL test_15();
CALL test_16();

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
DROP PROCEDURE IF EXISTS test_12;
DROP PROCEDURE IF EXISTS test_13;
DROP PROCEDURE IF EXISTS test_14;
DROP PROCEDURE IF EXISTS test_15;
DROP PROCEDURE IF EXISTS test_16;
DROP PROCEDURE IF EXISTS t_flow_seed;
DROP PROCEDURE IF EXISTS t_flow_state;
