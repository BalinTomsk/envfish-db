-- MySQL unit tests for the news-admin WRITE procedures added to mysql/script02_Proc.sql
-- (sp_news_admin_draft_create, sp_news_admin_publish, sp_news_admin_photo_update), which back
-- docapi's MySqlNewsAdminCommandRepository ("jdbc" profile) and, through it,
-- fishfind-frontend's Editor/AddNews.aspx admin authoring page -- see
-- fishfind-frontend/Editor/CLAUDE.md for the 2026-09-14 session that moved that page off SQL
-- Server's dbo.news. Run via mysql/UNIT_TESTS/autorun.bat against a throwaway database built
-- from mysql/ffi2.sql. NOT YET RUN against a live MySQL server as of writing (the workstation
-- cannot reach Winhost and no local MySQL 8 container was reachable this session -- see
-- envfish-db/CLAUDE.md "The workstation cannot reach the Winhost MySQL" for the standard
-- workaround); review carefully before trusting a green run blindly.
--
-- STRUCTURE: one stored PROCEDURE per test, each with its own EXIT HANDLER FOR SQLEXCEPTION and
-- its own transaction, rolled back at the end -- see envfish-db/CLAUDE.md "Structure MySQL unit
-- tests" and unit_test@NewsMySQL.sql for the pattern this mirrors.
--
-- WHY THESE TESTS CHECK TABLE STATE, NOT THE PROCEDURES' OWN RESULT SETS: MySQL cannot capture a
-- stored procedure's result set from calling SQL (no INSERT INTO t CALL proc(), no cursor-over-
-- CALL), so a test cannot assign `CALL sp_news_admin_publish(...)`'s SELECT output to a variable.
-- Every test here instead calls the procedure and then asserts on the `news` row it left behind,
-- which is what the caller (docapi) ultimately cares about anyway.
SET NAMES utf8mb4;

DELIMITER //

-- ----------------------------------------------------------------
-- TEST 1: sp_news_admin_draft_create purges unpublished drafts and creates one fresh row
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_01_draft_create_purges_and_inserts //
CREATE PROCEDURE test_01_draft_create_purges_and_inserts()
BEGIN
    DECLARE v_id CHAR(36);
    DECLARE v_stale_gone INT;
    DECLARE v_new_row INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 1 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish)
    VALUES ('a1000000-0000-0000-0000-000000000001', 'Stale Draft', 0);

    CALL sp_news_admin_draft_create(v_id);

    SELECT COUNT(*) INTO v_stale_gone FROM news WHERE news_id = 'a1000000-0000-0000-0000-000000000001';
    SELECT COUNT(*) INTO v_new_row FROM news
     WHERE news_id = v_id AND news_title = 'title' AND news_author = 'Lepsik' AND news_publish = 0;

    SELECT CASE WHEN v_id IS NOT NULL AND CHAR_LENGTH(v_id) = 36 AND v_stale_gone = 0 AND v_new_row = 1
                THEN 'TEST 1 PASS: stale draft purged, fresh placeholder draft created'
                ELSE CONCAT('TEST 1 FAIL: id=[', IFNULL(v_id, '<null>'), '] stale_gone=', v_stale_gone,
                            ' new_row=', v_new_row) END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 2: sp_news_admin_draft_create never purges a published article
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_02_draft_create_keeps_published //
CREATE PROCEDURE test_02_draft_create_keeps_published()
BEGIN
    DECLARE v_id CHAR(36);
    DECLARE v_still_there INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 2 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish)
    VALUES ('a1000000-0000-0000-0000-000000000002', 'Published Article', 1);

    CALL sp_news_admin_draft_create(v_id);

    SELECT COUNT(*) INTO v_still_there FROM news WHERE news_id = 'a1000000-0000-0000-0000-000000000002';

    SELECT CASE WHEN v_still_there = 1
                THEN 'TEST 2 PASS: a published article survives the draft purge'
                ELSE 'TEST 2 FAIL: a published article was deleted' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 3: sp_news_admin_publish inserts a full new row (upsert INSERT path)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_03_publish_inserts_new_row //
CREATE PROCEDURE test_03_publish_inserts_new_row()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 3 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    CALL sp_news_admin_publish(
        'a3000000-0000-0000-0000-000000000003', 'A Fisherman''s Tale', 'Some Author', 'Some Source',
        'https://source.example/a', 'https://author.example/a', '2026-01-02 03:04:05.000000',
        'https://video.example/a', 'Body zero.', 'Body one.', 'Body two.', 'CA',
        'b0000000-0000-0000-0000-00000000000b',
        'f1000000-0000-0000-0000-0000000000f1', NULL, NULL
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a3000000-0000-0000-0000-000000000003'
       AND news_title = 'A Fisherman''s Tale' AND news_author = 'Some Author' AND news_publish = 1
       AND country = 'CA' AND lake_id = 'b0000000-0000-0000-0000-00000000000b'
       AND fish1_id = 'f1000000-0000-0000-0000-0000000000f1' AND fish2_id IS NULL AND fish3_id IS NULL
       AND news_paragraph0 = 'Body zero.' AND news_paragraph2 = 'Body two.';

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 3 PASS: a fresh news_id is inserted with every field'
                ELSE 'TEST 3 FAIL: inserted row did not match the supplied fields' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 4: sp_news_admin_publish updates an existing row in place (upsert UPDATE path)
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_04_publish_updates_existing_row //
CREATE PROCEDURE test_04_publish_updates_existing_row()
BEGIN
    DECLARE v_ok INT;
    DECLARE v_count INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 4 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_author, news_publish)
    VALUES ('a4000000-0000-0000-0000-000000000004', 'title', 'Lepsik', 0);

    CALL sp_news_admin_publish(
        'a4000000-0000-0000-0000-000000000004', 'Real Title', 'Real Author', NULL, NULL, NULL,
        '2026-02-03 04:05:06.000000', NULL, 'Real body.', NULL, NULL, 'US', NULL, NULL, NULL, NULL
    );

    SELECT COUNT(*) INTO v_count FROM news WHERE news_id = 'a4000000-0000-0000-0000-000000000004';
    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a4000000-0000-0000-0000-000000000004'
       AND news_title = 'Real Title' AND news_author = 'Real Author' AND news_publish = 1
       AND country = 'US' AND news_paragraph0 = 'Real body.';

    SELECT CASE WHEN v_count = 1 AND v_ok = 1
                THEN 'TEST 4 PASS: an existing draft is updated in place, not duplicated'
                ELSE CONCAT('TEST 4 FAIL: row_count=', v_count, ' fields_ok=', v_ok) END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 5: sp_news_admin_publish called twice with byte-identical values does not error and
-- does not duplicate the row -- the MySQL "ROW_COUNT() counts CHANGED rows, not matched rows"
-- trap the procedure's own comment warns about.
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_05_publish_idempotent_resubmit //
CREATE PROCEDURE test_05_publish_idempotent_resubmit()
BEGIN
    DECLARE v_count INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 5 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    CALL sp_news_admin_publish(
        'a5000000-0000-0000-0000-000000000005', 'Same Title', 'Same Author', NULL, NULL, NULL,
        '2026-03-04 05:06:07.000000', NULL, 'Same body.', NULL, NULL, 'CA', NULL, NULL, NULL, NULL
    );
    CALL sp_news_admin_publish(
        'a5000000-0000-0000-0000-000000000005', 'Same Title', 'Same Author', NULL, NULL, NULL,
        '2026-03-04 05:06:07.000000', NULL, 'Same body.', NULL, NULL, 'CA', NULL, NULL, NULL, NULL
    );

    SELECT COUNT(*) INTO v_count FROM news WHERE news_id = 'a5000000-0000-0000-0000-000000000005';

    SELECT CASE WHEN v_count = 1
                THEN 'TEST 5 PASS: an identical resubmit neither errors nor duplicates the row'
                ELSE CONCAT('TEST 5 FAIL: expected exactly 1 row, found ', v_count) END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 6: sp_news_admin_photo_update writes bytes + author + alt onto slot 0
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_06_photo_update_writes_slot0 //
CREATE PROCEDURE test_06_photo_update_writes_slot0()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 6 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish)
    VALUES ('a6000000-0000-0000-0000-000000000006', 'title', 0);

    CALL sp_news_admin_photo_update(
        'a6000000-0000-0000-0000-000000000006', 0, 0x89504E47, 'Photo Author', 'Photo Alt'
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a6000000-0000-0000-0000-000000000006'
       AND news_photo0 = 0x89504E47 AND news_photo_author0 = 'Photo Author' AND news_photo_alt0 = 'Photo Alt';

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 6 PASS: slot 0 photo bytes/author/alt are all written'
                ELSE 'TEST 6 FAIL: slot 0 columns did not match' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 7: sp_news_admin_photo_update with NULL author/alt leaves the existing values alone
-- (COALESCE), while still replacing the photo bytes
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_07_photo_update_null_author_alt_preserved //
CREATE PROCEDURE test_07_photo_update_null_author_alt_preserved()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 7 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, news_photo1, news_photo_author1, news_photo_alt1)
    VALUES ('a7000000-0000-0000-0000-000000000007', 'title', 0, 0x00, 'Original Author', 'Original Alt');

    CALL sp_news_admin_photo_update(
        'a7000000-0000-0000-0000-000000000007', 1, 0x11223344, NULL, NULL
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a7000000-0000-0000-0000-000000000007'
       AND news_photo1 = 0x11223344 AND news_photo_author1 = 'Original Author' AND news_photo_alt1 = 'Original Alt';

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 7 PASS: NULL author/alt leave the existing values in place while bytes still update'
                ELSE 'TEST 7 FAIL: author/alt were overwritten, or bytes were not updated' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 8: sp_news_admin_photo_update on an unknown news_id changes nothing and inserts no
-- phantom row
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_08_photo_update_unknown_id_is_noop //
CREATE PROCEDURE test_08_photo_update_unknown_id_is_noop()
BEGIN
    DECLARE v_count INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 8 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    CALL sp_news_admin_photo_update(
        'a8000000-0000-0000-0000-000000000008', 0, 0x89504E47, 'X', 'Y'
    );

    SELECT COUNT(*) INTO v_count FROM news WHERE news_id = 'a8000000-0000-0000-0000-000000000008';

    SELECT CASE WHEN v_count = 0
                THEN 'TEST 8 PASS: an unknown news_id is a clean no-op, no row is created'
                ELSE 'TEST 8 FAIL: a phantom row was created for an unknown news_id' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 9: sp_news_admin_photo_update with an out-of-range index touches no column on an
-- otherwise-existing row
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_09_photo_update_bad_index_noop //
CREATE PROCEDURE test_09_photo_update_bad_index_noop()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 9 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, news_photo0)
    VALUES ('a9000000-0000-0000-0000-000000000009', 'title', 0, 0xAABBCC);

    CALL sp_news_admin_photo_update(
        'a9000000-0000-0000-0000-000000000009', 3, 0x99887766, 'Should Not Apply', 'Should Not Apply'
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a9000000-0000-0000-0000-000000000009'
       AND news_photo0 = 0xAABBCC AND news_photo_author0 IS NULL;

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 9 PASS: an out-of-range index leaves every photo column untouched'
                ELSE 'TEST 9 FAIL: a column changed despite an invalid slot index' END AS message;
    ROLLBACK;
END //

-- ----------------------------------------------------------------
-- TEST 10: slots 0/1/2 are independent -- writing slot 1 never touches slot 0 or slot 2
-- ----------------------------------------------------------------
DROP PROCEDURE IF EXISTS test_10_photo_update_slots_independent //
CREATE PROCEDURE test_10_photo_update_slots_independent()
BEGIN
    DECLARE v_ok INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SELECT 'TEST 10 FAIL: unexpected SQL error' AS message;
    END;

    START TRANSACTION;
    INSERT INTO news (news_id, news_title, news_publish, news_photo0, news_photo2)
    VALUES ('a1000000-0000-0000-0000-000000000010', 'title', 0, 0x01, 0x02);

    CALL sp_news_admin_photo_update(
        'a1000000-0000-0000-0000-000000000010', 1, 0x03, 'Slot1 Author', 'Slot1 Alt'
    );

    SELECT COUNT(*) INTO v_ok FROM news
     WHERE news_id = 'a1000000-0000-0000-0000-000000000010'
       AND news_photo0 = 0x01 AND news_photo1 = 0x03 AND news_photo2 = 0x02
       AND news_photo_author1 = 'Slot1 Author' AND news_photo_alt1 = 'Slot1 Alt';

    SELECT CASE WHEN v_ok = 1
                THEN 'TEST 10 PASS: writing slot 1 leaves slot 0 and slot 2 untouched'
                ELSE 'TEST 10 FAIL: a write to slot 1 leaked into another slot' END AS message;
    ROLLBACK;
END //

DELIMITER ;

-- ==================================================================
-- Run every test. Each CALL is independent (its own transaction + EXIT HANDLER), so one test's
-- failure or unexpected SQL error does not prevent the rest from running.
-- ==================================================================
CALL test_01_draft_create_purges_and_inserts();
CALL test_02_draft_create_keeps_published();
CALL test_03_publish_inserts_new_row();
CALL test_04_publish_updates_existing_row();
CALL test_05_publish_idempotent_resubmit();
CALL test_06_photo_update_writes_slot0();
CALL test_07_photo_update_null_author_alt_preserved();
CALL test_08_photo_update_unknown_id_is_noop();
CALL test_09_photo_update_bad_index_noop();
CALL test_10_photo_update_slots_independent();

-- Clean up the test procedures themselves so the throwaway database ends in the same shape
-- ffi2.sql produced (no lasting state change -- the same rule each test's ROLLBACK follows).
DROP PROCEDURE IF EXISTS test_01_draft_create_purges_and_inserts;
DROP PROCEDURE IF EXISTS test_02_draft_create_keeps_published;
DROP PROCEDURE IF EXISTS test_03_publish_inserts_new_row;
DROP PROCEDURE IF EXISTS test_04_publish_updates_existing_row;
DROP PROCEDURE IF EXISTS test_05_publish_idempotent_resubmit;
DROP PROCEDURE IF EXISTS test_06_photo_update_writes_slot0;
DROP PROCEDURE IF EXISTS test_07_photo_update_null_author_alt_preserved;
DROP PROCEDURE IF EXISTS test_08_photo_update_unknown_id_is_noop;
DROP PROCEDURE IF EXISTS test_09_photo_update_bad_index_noop;
DROP PROCEDURE IF EXISTS test_10_photo_update_slots_independent;
