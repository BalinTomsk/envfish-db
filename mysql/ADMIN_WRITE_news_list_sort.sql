-- ============================================================================================
-- PRODUCTION SETUP -- run this in the Winhost MySQL control panel (phpMyAdmin / DB manager)
-- Database: mysql_111487_envfish
--
-- WHAT IT DOES
-- ------------
-- Replaces sp_news_list_json (behind docapi's GET /api/v1/news/list, used by News.aspx) with the
-- envfish-db #62 version: news listed newest-ADDED first (id DESC) instead of by the article's own
-- date (news_stamp DESC). Copied verbatim from mysql/script02_Proc.sql @ main; keep them identical.
-- Idempotent (DROP + CREATE). Changes no data, no table, no other procedure.
--
-- WHY THE CONTROL PANEL
-- ---------------------
-- `portos` (the app's MySQL account) has no CREATE ROUTINE -- see ADMIN_WRITE_news_procs.sql.
-- The control panel connects as the database owner, which is how the current version was created.
-- portos already has EXECUTE, so docapi can CALL the new version with no grant change.
--
-- AFTER RUNNING THIS FILE
-- -----------------------
-- 1. Check it:   CALL sp_news_list_json('', 0, 5);
--    Expect rows in descending `id` order (the newest-added article first), whatever their dates.
-- 2. Restart the jnode (docapi) service. docapi keeps /news/list pages in memory (NewsQueryCache)
--    and only clears them at 00:00 UTC or on restart, so News.aspx keeps the old order until then.
--
-- ROLLBACK: run ADMIN_ROLLBACK_news_list_sort.sql (the previous definition), then restart jnode.
-- ============================================================================================

DELIMITER //

DROP PROCEDURE IF EXISTS sp_news_list_json //
CREATE PROCEDURE sp_news_list_json(
    IN p_country VARCHAR(2) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_offset INT,
    IN p_limit INT
)
BEGIN
    DECLARE v_offset INT DEFAULT IF(p_offset < 0, 0, p_offset);
    DECLARE v_limit INT DEFAULT IF(p_limit < 1, 25, IF(p_limit > 200, 200, p_limit));
    DECLARE v_country VARCHAR(2) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULLIF(p_country, '');
    DECLARE v_own_count INT DEFAULT 0;
    DECLARE v_pad_limit INT DEFAULT 0;

    IF v_country IS NOT NULL AND v_country <> 'CA' THEN
        SELECT COUNT(*) INTO v_own_count FROM v_news_list_rows WHERE country = v_country;
        SET v_pad_limit = GREATEST(100 - v_own_count, 0);
    END IF;

    -- Row source is v_news_list_rows (the shared per-row projection); the country filter, the CA
    -- padding block, and the rn/total window functions are applied here because they depend on the
    -- caller's parameters, which a view cannot take.
    SELECT rn, news_id, title, source, stamp, flag, has_photo, block_ord, total
    FROM (
        SELECT
            -- Newest ADDED first: id is news's AUTO_INCREMENT, i.e. insertion order (a new article's
            -- row is created when AddNews opens its draft). Ordering by news_stamp -- the article's own
            -- date, which the editor sets -- put a just-added article dated a week back below older
            -- entries, so it looked missing from the list.
            ROW_NUMBER() OVER (ORDER BY block_ord ASC, id DESC) AS rn,
            COUNT(*) OVER () AS total,
            news_id, title, source, stamp, flag, has_photo, block_ord
        FROM (
            -- PRIMARY block: the requested country, or every country when blank.
            SELECT id, news_id, title, source, news_stamp, stamp, flag, has_photo, 0 AS block_ord
            FROM v_news_list_rows
            WHERE v_country IS NULL OR country = v_country
            UNION ALL
            -- PADDING block: latest CA news topping the list up to 100, only for a non-CA country
            -- short of 100 of its own.
            SELECT id, news_id, title, source, news_stamp, stamp, flag, has_photo, 1 AS block_ord
            FROM (
                SELECT id, news_id, title, source, news_stamp, stamp, flag, has_photo,
                       ROW_NUMBER() OVER (ORDER BY id DESC) AS pad_rn
                FROM v_news_list_rows
                WHERE v_country IS NOT NULL AND v_country <> 'CA' AND country = 'CA'
            ) pad
            WHERE pad.pad_rn <= v_pad_limit
        ) combined
    ) ranked
    ORDER BY rn
    LIMIT v_offset, v_limit;
END //

DELIMITER ;
