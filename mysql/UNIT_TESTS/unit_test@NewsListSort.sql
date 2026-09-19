-- MySQL unit tests for the news list SORT ORDER (2026-09-18): the `news.edit_stamp` column, the
-- `last_edit` key on v_news_list_rows, the four write procedures that must stamp it, and the
-- contract of sp_news_list_json's p_sort parameter.
--
-- THE RULE BEING PINNED: /news/list is ordered by the role of the caller (docapi decides the role
-- from cproxy's verified X-Fish-Role header and passes it down as p_sort):
--     admin           -> 'edited' : most recently EDITED article first  (COALESCE(edit_stamp, stamp) DESC)
--     registered/guest -> 'date'  : newest article DATE first           (news_stamp DESC)
-- This replaces the 2026-09-18 insertion-order (id DESC) sort, which ordered by when a row was created
-- and so ignored both the article's own date and any later edit.
--
-- WHY THE ORDERING ITSELF IS NOT ASSERTED HERE: MySQL cannot capture a stored procedure's result set
-- from calling SQL (see unit_test@NewsMySQL.sql), and p_sort/country are parameters a view cannot
-- take. So this file asserts the two things the ordering is built from -- the sort keys the view
-- exposes and the writes that maintain them -- plus the procedure's definition (TEST 8, same
-- technique as unit_test@NewsMySQL.sql TEST 23). The ORDER itself was verified by CALLing the
-- procedure against a real MySQL 8.0.46; that run is recorded in envfish-db/CHANGELOG.md.
--
-- STRUCTURE: one PROCEDURE per test, own EXIT HANDLER, own transaction, ROLLBACK at the end.
SET NAMES utf8mb4;

DELIMITER //

-- ----------------------------------------------------------------
-- TEST 1: news.edit_stamp exists, is a nullable DATETIME(6)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_01_edit_stamp_column //
CREATE PROCEDURE test_01_edit_stamp_column()
BEGIN
    DECLARE v_type VARCHAR(64);
    DECLARE v_null VARCHAR(3);
    DECLARE v_prec INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SELECT 'TEST 1 FAIL: unexpected SQL error' AS message;
    END;

    SELECT data_type, is_nullable, datetime_precision INTO v_type, v_null, v_prec
    FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = 'news' AND column_name = 'edit_stamp';

    SELECT CASE WHEN v_type IS NULL THEN 'TEST 1 FAIL: news.edit_stamp does not exist'
                WHEN v_type = 'datetime' AND v_null = 'YES' AND v_prec = 6
                THEN 'TEST 1 PASS: news.edit_stamp is a nullable DATETIME(6)'
                ELSE 'TEST 1 FAIL: edit_stamp is not a nullable DATETIME(6)' END AS message;
END //

-- ----------------------------------------------------------------
-- TEST 2: v_news_list_rows.last_edit is the edit stamp, and falls back to the row stamp when never edited
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_02_view_last_edit_key //
CREATE PROCEDURE test_02_view_last_edit_key()
BEGIN
    DECLARE v_edited DATETIME(6);
    DECLARE v_never DATETIME(6);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 2 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, news_stamp, stamp, edit_stamp)
    VALUES ('c1000000-0000-0000-0000-000000000001', 'Edited', 1, '2020-01-01 00:00:00.000000',
            '2020-02-01 00:00:00.000000', '2026-05-05 05:05:05.000000');
    INSERT INTO news (news_id, news_title, news_publish, news_stamp, stamp, edit_stamp)
    VALUES ('c1000000-0000-0000-0000-000000000002', 'Never edited', 1, '2020-01-01 00:00:00.000000',
            '2020-02-01 00:00:00.000000', NULL);

    SELECT last_edit INTO v_edited FROM v_news_list_rows WHERE news_id = 'c1000000-0000-0000-0000-000000000001';
    SELECT last_edit INTO v_never  FROM v_news_list_rows WHERE news_id = 'c1000000-0000-0000-0000-000000000002';

    SELECT CASE WHEN v_edited = '2026-05-05 05:05:05.000000' AND v_never = '2020-02-01 00:00:00.000000'
                THEN 'TEST 2 PASS: last_edit is edit_stamp, or the row stamp when never edited'
                ELSE 'TEST 2 FAIL: last_edit is not edit_stamp or the stamp fallback' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 3: the view still exposes the article DATE key (news_stamp) the 'date' sort orders by
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_03_view_keeps_news_stamp //
CREATE PROCEDURE test_03_view_keeps_news_stamp()
BEGIN
    DECLARE v_ns DATETIME(6);
    DECLARE v_disp VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 3 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, news_stamp, edit_stamp)
    VALUES ('c1000000-0000-0000-0000-000000000003', 'Dated', 1, '2019-07-08 09:10:11.000000', '2026-01-01 00:00:00.000000');

    SELECT news_stamp, stamp INTO v_ns, v_disp FROM v_news_list_rows WHERE news_id = 'c1000000-0000-0000-0000-000000000003';

    SELECT CASE WHEN v_ns = '2019-07-08 09:10:11.000000' AND v_disp = '2019-07-08'
                THEN 'TEST 3 PASS: view keeps news_stamp and its display stamp by last_edit'
                ELSE 'TEST 3 FAIL: view lost news_stamp or its yyyy-mm-dd display stamp' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 4: sp_news_admin_draft_create stamps edit_stamp
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_04_draft_create_stamps_edit //
CREATE PROCEDURE test_04_draft_create_stamps_edit()
BEGIN
    DECLARE v_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci;
    DECLARE v_stamp DATETIME(6);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 4 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    CALL sp_news_admin_draft_create(v_id);
    SELECT edit_stamp INTO v_stamp FROM news WHERE news_id = v_id;

    SELECT CASE WHEN v_stamp IS NOT NULL AND ABS(TIMESTAMPDIFF(SECOND, v_stamp, NOW(6))) <= 5
                THEN 'TEST 4 PASS: a new draft carries an edit_stamp of now'
                ELSE 'TEST 4 FAIL: a new draft has no edit_stamp of now' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 5: sp_news_admin_publish stamps edit_stamp on BOTH branches (update of an old row, insert of a new one)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_05_publish_stamps_edit //
CREATE PROCEDURE test_05_publish_stamps_edit()
BEGIN
    DECLARE v_upd DATETIME(6);
    DECLARE v_ins DATETIME(6);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 5 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, edit_stamp)
    VALUES ('c1000000-0000-0000-0000-000000000005', 'Old', 1, '2020-01-01 00:00:00.000000');

    CALL sp_news_admin_publish('c1000000-0000-0000-0000-000000000005', 'Old, edited', NULL, NULL, NULL, NULL,
        '2020-01-01 00:00:00.000000', NULL, 'x', NULL, NULL, 'CA', NULL, NULL, NULL, NULL);
    CALL sp_news_admin_publish('c1000000-0000-0000-0000-000000000105', 'Brand new', NULL, NULL, NULL, NULL,
        '2020-01-01 00:00:00.000000', NULL, 'x', NULL, NULL, 'CA', NULL, NULL, NULL, NULL);

    SELECT edit_stamp INTO v_upd FROM news WHERE news_id = 'c1000000-0000-0000-0000-000000000005';
    SELECT edit_stamp INTO v_ins FROM news WHERE news_id = 'c1000000-0000-0000-0000-000000000105';

    SELECT CASE WHEN ABS(TIMESTAMPDIFF(SECOND, v_upd, NOW(6))) <= 5 AND ABS(TIMESTAMPDIFF(SECOND, v_ins, NOW(6))) <= 5
                THEN 'TEST 5 PASS: publish stamps edit_stamp on both update and insert'
                ELSE 'TEST 5 FAIL: publish did not stamp edit_stamp on both paths' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 6: sp_news_admin_photo_update stamps edit_stamp (a photo change is an edit)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_06_photo_update_stamps_edit //
CREATE PROCEDURE test_06_photo_update_stamps_edit()
BEGIN
    DECLARE v_stamp DATETIME(6);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 6 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, edit_stamp)
    VALUES ('c1000000-0000-0000-0000-000000000006', 'Photo', 1, '2020-01-01 00:00:00.000000');

    CALL sp_news_admin_photo_update('c1000000-0000-0000-0000-000000000006', 1, 0x89504E47, 'A', 'B');
    SELECT edit_stamp INTO v_stamp FROM news WHERE news_id = 'c1000000-0000-0000-0000-000000000006';

    SELECT CASE WHEN ABS(TIMESTAMPDIFF(SECOND, v_stamp, NOW(6))) <= 5
                THEN 'TEST 6 PASS: replacing a photo stamps edit_stamp'
                ELSE 'TEST 6 FAIL: photo update did not stamp edit_stamp' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 7: sp_news_doc_insert and sp_news_doc_update (docapi's POST/PUT/import) stamp edit_stamp
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_07_doc_writes_stamp_edit //
CREATE PROCEDURE test_07_doc_writes_stamp_edit()
BEGIN
    DECLARE v_ins DATETIME(6);
    DECLARE v_upd DATETIME(6);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 7 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    CALL sp_news_doc_insert('T7 Inserted', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        '2020-01-01 00:00:00.000000', NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    SELECT edit_stamp INTO v_ins FROM news WHERE news_title = 'T7 Inserted';

    INSERT INTO news (news_id, news_title, news_publish, edit_stamp)
    VALUES ('c1000000-0000-0000-0000-000000000007', 'T7 Old', 1, '2020-01-01 00:00:00.000000');
    CALL sp_news_doc_update('c1000000-0000-0000-0000-000000000007', 'T7 Updated', NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
    SELECT edit_stamp INTO v_upd FROM news WHERE news_id = 'c1000000-0000-0000-0000-000000000007';

    SELECT CASE WHEN ABS(TIMESTAMPDIFF(SECOND, v_ins, NOW(6))) <= 5 AND ABS(TIMESTAMPDIFF(SECOND, v_upd, NOW(6))) <= 5
                THEN 'TEST 7 PASS: sp_news_doc_insert and sp_news_doc_update stamp edit_stamp'
                ELSE 'TEST 7 FAIL: doc insert/update did not stamp edit_stamp' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 8: sp_news_list_json's definition -- a fourth p_sort parameter, ordered by the role's key, and no
-- longer by insertion id. Asserts information_schema, so it fails if the procedure in the database
-- drifts from the file.
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_08_list_procedure_contract //
CREATE PROCEDURE test_08_list_procedure_contract()
BEGIN
    DECLARE v_body LONGTEXT;
    DECLARE v_params INT;
    DECLARE v_sort_type VARCHAR(20);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SELECT 'TEST 8 FAIL: unexpected SQL error' AS message;
    END;

    SELECT routine_definition INTO v_body
    FROM information_schema.routines
    WHERE routine_schema = DATABASE() AND routine_name = 'sp_news_list_json';

    SELECT COUNT(*), MAX(CASE WHEN parameter_name = 'p_sort' THEN data_type END) INTO v_params, v_sort_type
    FROM information_schema.parameters
    WHERE specific_schema = DATABASE() AND specific_name = 'sp_news_list_json' AND parameter_name IS NOT NULL;

    SELECT CASE WHEN v_body IS NULL THEN 'TEST 8 FAIL: sp_news_list_json is not present in this database'
                WHEN v_params <> 4 OR v_sort_type IS NULL
                THEN 'TEST 8 FAIL: sp_news_list_json does not have 4 parameters'
                WHEN LOCATE('last_edit', v_body) = 0
                THEN 'TEST 8 FAIL: sp_news_list_json never orders by last_edit'
                WHEN LOCATE('news_stamp', v_body) = 0
                THEN 'TEST 8 FAIL: sp_news_list_json never orders by news_stamp'
                WHEN LOCATE('sort_key DESC', v_body) = 0
                THEN 'TEST 8 FAIL: sp_news_list_json does not rank by the chosen sort_key'
                ELSE 'TEST 8 PASS: sp_news_list_json takes p_sort, orders by last_edit/stamp' END AS message;
END //

DELIMITER ;

CALL test_01_edit_stamp_column();
CALL test_02_view_last_edit_key();
CALL test_03_view_keeps_news_stamp();
CALL test_04_draft_create_stamps_edit();
CALL test_05_publish_stamps_edit();
CALL test_06_photo_update_stamps_edit();
CALL test_07_doc_writes_stamp_edit();
CALL test_08_list_procedure_contract();

DROP PROCEDURE IF EXISTS test_01_edit_stamp_column;
DROP PROCEDURE IF EXISTS test_02_view_last_edit_key;
DROP PROCEDURE IF EXISTS test_03_view_keeps_news_stamp;
DROP PROCEDURE IF EXISTS test_04_draft_create_stamps_edit;
DROP PROCEDURE IF EXISTS test_05_publish_stamps_edit;
DROP PROCEDURE IF EXISTS test_06_photo_update_stamps_edit;
DROP PROCEDURE IF EXISTS test_07_doc_writes_stamp_edit;
DROP PROCEDURE IF EXISTS test_08_list_procedure_contract;
