-- ============================================================================================
-- ROLLBACK for ADMIN_WRITE_news_list_sort.sql -- run in the Winhost MySQL control panel
-- Database: mysql_111487_envfish
--
-- Restores sp_news_list_json as it was before envfish-db #62 (commit daecb67): news listed by the
-- article's own date, newest first (news_stamp DESC, id DESC). Idempotent (DROP + CREATE).
-- Afterwards restart the jnode (docapi) service so its in-memory list cache is cleared.
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
            ROW_NUMBER() OVER (ORDER BY block_ord ASC, news_stamp DESC, id DESC) AS rn,
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
                       ROW_NUMBER() OVER (ORDER BY news_stamp DESC, id DESC) AS pad_rn
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
